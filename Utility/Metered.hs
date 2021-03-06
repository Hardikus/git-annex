{- Metered IO
 -
 - Copyright 2012, 2013 Joey Hess <joey@kitenet.net>
 -
 - License: BSD-2-clause
 -}

{-# LANGUAGE TypeSynonymInstances #-}

module Utility.Metered where

import Common

import qualified Data.ByteString.Lazy as L
import qualified Data.ByteString as S
import System.IO.Unsafe
import Foreign.Storable (Storable(sizeOf))
import System.Posix.Types
import Data.Int

{- An action that can be run repeatedly, updating it on the bytes processed.
 -
 - Note that each call receives the total number of bytes processed, so
 - far, *not* an incremental amount since the last call. -}
type MeterUpdate = (BytesProcessed -> IO ())

nullMeterUpdate :: MeterUpdate
nullMeterUpdate _ = return ()

{- Total number of bytes processed so far. -}
newtype BytesProcessed = BytesProcessed Integer
	deriving (Eq, Ord, Show)

class AsBytesProcessed a where
	toBytesProcessed :: a -> BytesProcessed
	fromBytesProcessed :: BytesProcessed -> a

instance AsBytesProcessed BytesProcessed where
	toBytesProcessed = id
	fromBytesProcessed = id

instance AsBytesProcessed Integer where
	toBytesProcessed i = BytesProcessed i
	fromBytesProcessed (BytesProcessed i) = i

instance AsBytesProcessed Int where
	toBytesProcessed i = BytesProcessed $ toInteger i
	fromBytesProcessed (BytesProcessed i) = fromInteger i

instance AsBytesProcessed Int64 where
	toBytesProcessed i = BytesProcessed $ toInteger i
	fromBytesProcessed (BytesProcessed i) = fromInteger i

instance AsBytesProcessed FileOffset where
	toBytesProcessed sz = BytesProcessed $ toInteger sz
	fromBytesProcessed (BytesProcessed sz) = fromInteger sz

addBytesProcessed :: AsBytesProcessed v => BytesProcessed -> v -> BytesProcessed
addBytesProcessed (BytesProcessed i) v = 
	let (BytesProcessed n) = toBytesProcessed v
	in BytesProcessed $! i + n

zeroBytesProcessed :: BytesProcessed
zeroBytesProcessed = BytesProcessed 0

{- Sends the content of a file to an action, updating the meter as it's
 - consumed. -}
withMeteredFile :: FilePath -> MeterUpdate -> (L.ByteString -> IO a) -> IO a
withMeteredFile f meterupdate a = withBinaryFile f ReadMode $ \h ->
	hGetContentsMetered h meterupdate >>= a

{- Sends the content of a file to a Handle, updating the meter as it's
 - written. -}
streamMeteredFile :: FilePath -> MeterUpdate -> Handle -> IO ()
streamMeteredFile f meterupdate h = withMeteredFile f meterupdate $ L.hPut h

{- Writes a ByteString to a Handle, updating a meter as it's written. -}
meteredWrite :: MeterUpdate -> Handle -> L.ByteString -> IO ()
meteredWrite meterupdate h = go zeroBytesProcessed . L.toChunks 
  where
	go _ [] = return ()
	go sofar (c:cs) = do
		S.hPut h c
		let sofar' = addBytesProcessed sofar $ S.length c
		meterupdate sofar'
		go sofar' cs

meteredWriteFile :: MeterUpdate -> FilePath -> L.ByteString -> IO ()
meteredWriteFile meterupdate f b = withBinaryFile f WriteMode $ \h ->
	meteredWrite meterupdate h b

{- Applies an offset to a MeterUpdate. This can be useful when
 - performing a sequence of actions, such as multiple meteredWriteFiles,
 - that all update a common meter progressively. Or when resuming.
 -}
offsetMeterUpdate :: MeterUpdate -> BytesProcessed -> MeterUpdate
offsetMeterUpdate base offset = \n -> base (offset `addBytesProcessed` n)

{- This is like L.hGetContents, but after each chunk is read, a meter
 - is updated based on the size of the chunk.
 -
 - All the usual caveats about using unsafeInterleaveIO apply to the
 - meter updates, so use caution.
 -}
hGetContentsMetered :: Handle -> MeterUpdate -> IO L.ByteString
hGetContentsMetered h = hGetUntilMetered h (const True)

{- Reads from the Handle, updating the meter after each chunk.
 -
 - Note that the meter update is run in unsafeInterleaveIO, which means that
 - it can be run at any time. It's even possible for updates to run out
 - of order, as different parts of the ByteString are consumed.
 -
 - Stops at EOF, or when keepgoing evaluates to False.
 - Closes the Handle at EOF, but otherwise leaves it open.
 -}
hGetUntilMetered :: Handle -> (Integer -> Bool) -> MeterUpdate -> IO L.ByteString
hGetUntilMetered h keepgoing meterupdate = lazyRead zeroBytesProcessed
  where
	lazyRead sofar = unsafeInterleaveIO $ loop sofar

	loop sofar = do
		c <- S.hGet h defaultChunkSize
		if S.null c
			then do
				hClose h
				return $ L.empty
			else do
				let sofar' = addBytesProcessed sofar (S.length c)
				meterupdate sofar'
				if keepgoing (fromBytesProcessed sofar')
					then do
						{- unsafeInterleaveIO causes this to be
						 - deferred until the data is read from the
						 - ByteString. -}
						cs <- lazyRead sofar'
						return $ L.append (L.fromChunks [c]) cs
					else return $ L.fromChunks [c]

{- Same default chunk size Lazy ByteStrings use. -}
defaultChunkSize :: Int
defaultChunkSize = 32 * k - chunkOverhead
  where
	k = 1024
	chunkOverhead = 2 * sizeOf (undefined :: Int) -- GHC specific

{- Parses the String looking for a command's progress output, and returns
 - Maybe the number of bytes rsynced so far, and any any remainder of the
 - string that could be an incomplete progress output. That remainder
 - should be prepended to future output, and fed back in. This interface
 - allows the command's output to be read in any desired size chunk, or
 - even one character at a time.
 -}
type ProgressParser = String -> (Maybe BytesProcessed, String)

{- Runs a command and runs a ProgressParser on its output, in order
 - to update the meter. The command's output is also sent to stdout. -}
commandMeter :: ProgressParser -> MeterUpdate -> FilePath -> [CommandParam] -> IO Bool
commandMeter progressparser meterupdate cmd params = liftIO $ catchBoolIO $
	withHandle StdoutHandle createProcessSuccess p $
		feedprogress zeroBytesProcessed []
  where
	p = proc cmd (toCommand params)

	feedprogress prev buf h = do
		s <- hGetSomeString h 80
		if null s
			then return True
			else do
				putStr s
				hFlush stdout
				let (mbytes, buf') = progressparser (buf++s)
				case mbytes of
					Nothing -> feedprogress prev buf' h
					(Just bytes) -> do
						when (bytes /= prev) $
							meterupdate bytes
						feedprogress bytes buf' h
