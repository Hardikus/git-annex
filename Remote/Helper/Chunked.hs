{- git-annex chunked remotes
 -
 - Copyright 2014 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Remote.Helper.Chunked (
	ChunkSize,
	ChunkConfig(..),
	chunkConfig,
	storeChunks,
	removeChunks,
	retrieveChunks,
	hasKeyChunks,
) where

import Common.Annex
import Utility.DataUnits
import Types.Remote
import Types.Key
import Logs.Chunk.Pure (ChunkSize, ChunkCount)
import Logs.Chunk
import Utility.Metered
import Crypto (EncKey)
import Annex.Exception

import qualified Data.ByteString.Lazy as L
import qualified Data.Map as M
import Control.Exception

data ChunkConfig
	= NoChunks
	| UnpaddedChunks ChunkSize
	| LegacyChunks ChunkSize

noChunks :: ChunkConfig -> Bool
noChunks NoChunks = True
noChunks _ = False

chunkConfig :: RemoteConfig -> ChunkConfig
chunkConfig m =
	case M.lookup "chunksize" m of
		Nothing -> case M.lookup "chunk" m of
			Nothing -> NoChunks
			Just v -> UnpaddedChunks $ readsz v "chunk"
		Just v -> LegacyChunks $ readsz v "chunksize"
  where
	readsz v f = case readSize dataUnits v of
		Just size | size > 0 -> fromInteger size
		_ -> error ("bad " ++ f)

-- An infinite stream of chunk keys, starting from chunk 1.
newtype ChunkKeyStream = ChunkKeyStream [Key]

chunkKeyStream :: Key -> ChunkSize -> ChunkKeyStream
chunkKeyStream basek chunksize = ChunkKeyStream $ map mk [1..]
  where
	mk chunknum = sizedk { keyChunkNum = Just chunknum }
	sizedk = basek { keyChunkSize = Just (toInteger chunksize) }

nextChunkKeyStream :: ChunkKeyStream -> (Key, ChunkKeyStream)
nextChunkKeyStream (ChunkKeyStream (k:l)) = (k, ChunkKeyStream l)
nextChunkKeyStream (ChunkKeyStream []) = undefined -- stream is infinite!

takeChunkKeyStream :: ChunkCount -> ChunkKeyStream -> [Key]
takeChunkKeyStream n (ChunkKeyStream l) = genericTake n l

-- Number of chunks already consumed from the stream.
numChunks :: ChunkKeyStream -> Integer
numChunks = pred . fromJust . keyChunkNum . fst . nextChunkKeyStream

{- Splits up the key's content into chunks, passing each chunk to
 - the storer action, along with a corresponding chunk key and a
 - progress meter update callback.
 -
 - This buffers each chunk in memory, so can use a lot of memory
 - with a large ChunkSize.
 - More optimal versions of this can be written, that rely
 - on L.toChunks to split the lazy bytestring into chunks (typically
 - smaller than the ChunkSize), and eg, write those chunks to a Handle.
 - But this is the best that can be done with the storer interface that
 - writes a whole L.ByteString at a time.
 -}
storeChunks
	:: UUID
	-> ChunkConfig
	-> Key
	-> FilePath
	-> MeterUpdate
	-> (Key -> L.ByteString -> MeterUpdate -> IO Bool)
	-> Annex Bool
storeChunks u chunkconfig k f p storer = metered (Just p) k $ \meterupdate ->
	either (\e -> warning (show e) >> return False) (go meterupdate)
		=<< (liftIO $ tryIO $ L.readFile f)
  where
	go meterupdate b = case chunkconfig of
		(UnpaddedChunks chunksize) ->
			gochunks meterupdate chunksize b (chunkKeyStream k chunksize)
		_ -> liftIO $ storer k b meterupdate

	gochunks :: MeterUpdate -> ChunkSize -> L.ByteString -> ChunkKeyStream -> Annex Bool
	gochunks meterupdate chunksize = loop zeroBytesProcessed . splitchunk
	  where
		splitchunk = L.splitAt chunksize
	
		loop bytesprocessed (chunk, bs) chunkkeys
			| L.null chunk && numchunks > 0 = do
 				-- Once all chunks are successfully
				-- stored, update the chunk log.
				chunksStored u k chunksize numchunks
				return True
			| otherwise = do
				let (chunkkey, chunkkeys') = nextChunkKeyStream chunkkeys
				ifM (liftIO $ storer chunkkey chunk meterupdate')
					( do
						let bytesprocessed' = addBytesProcessed bytesprocessed (L.length chunk)
						loop bytesprocessed' (splitchunk bs) chunkkeys'
					, return False
					)
		  where
			numchunks = numChunks chunkkeys
 			{- The MeterUpdate that is passed to the action
			 - storing a chunk is offset, so that it reflects
			 - the total bytes that have already been stored
			 - in previous chunks. -}
			meterupdate' = offsetMeterUpdate meterupdate bytesprocessed

{- Removes all chunks of a key from a remote, by calling a remover
 - action on each.
 -
 - The remover action should succeed even if asked to
 - remove a key that is not present on the remote.
 -
 - This action may be called on a chunked key. It will simply remove it.
 -}
removeChunks :: (Key -> Annex Bool) -> UUID -> ChunkConfig -> EncKey -> Key -> Annex Bool
removeChunks remover u chunkconfig encryptor k = do
	ls <- chunkKeys u chunkconfig k
	ok <- allM (remover . encryptor) (concat ls)
	when ok $ do
		let chunksizes = catMaybes $ map (keyChunkSize <=< headMaybe) ls
		forM_ chunksizes $ chunksRemoved u k . fromIntegral
	return ok

{- Retrieves a key from a remote, using a retriever action that
 - streams it to a ByteString.
 -
 - When the remote is chunked, tries each of the options returned by
 - chunkKeys until it finds one where the retriever successfully
 - gets the first chunked key. The content of that key, and any
 - other chunks in the list is fed to the sink.
 -
 - If retrival of one of the subsequent chunks throws an exception,
 - gives up and returns False. Note that partial data may have been
 - written to the sink in this case.
 -
 - Resuming is supported when using chunks. When the destination file
 - already exists, it skips to the next chunked key that would be needed
 - to resume.
 -}
retrieveChunks 
	:: (Key -> IO L.ByteString)
	-> UUID
	-> ChunkConfig
	-> EncKey
	-> Key
	-> FilePath
	-> MeterUpdate
	-> (Handle -> MeterUpdate -> L.ByteString -> IO ())
	-> Annex Bool
retrieveChunks retriever u chunkconfig encryptor basek dest basep sink
	| noChunks chunkconfig =
		-- Optimisation: Try the unchunked key first, to avoid
		-- looking in the git-annex branch for chunk counts
		-- that are likely not there.
		getunchunked `catchNonAsyncAnnex`
			const (go =<< chunkKeysOnly u basek)
	| otherwise = go =<< chunkKeys u chunkconfig basek
  where
	go ls = liftIO $ do
		currsize <- catchMaybeIO $
			toInteger . fileSize <$> getFileStatus dest
		let ls' = maybe ls (setupResume ls) currsize
		firstavail currsize ls' `catchNonAsync` giveup

	giveup e = do
		warningIO (show e)
		return False

	firstavail _ [] = return False
	firstavail currsize ([]:ls) = firstavail currsize ls
	firstavail currsize ((k:ks):ls) = do
		v <- tryNonAsync $ retriever (encryptor k)
		case v of
			Left e
				| null ls -> giveup e
				| otherwise -> firstavail currsize ls
			Right b -> do
				let offset = resumeOffset currsize k
				let p = maybe basep
					(offsetMeterUpdate basep . toBytesProcessed)
					offset
				bracket (maybe opennew openresume offset) hClose $ \h -> do
					sink h p b
					let sz = toBytesProcessed $
						fromMaybe 0 $ keyChunkSize k
					getrest p h sz sz ks

	getrest _ _ _ _ [] = return True
	getrest p h sz bytesprocessed (k:ks) = do
		let p' = offsetMeterUpdate p bytesprocessed
		sink h p' =<< retriever (encryptor k)
		getrest p h sz (addBytesProcessed bytesprocessed sz) ks

	getunchunked = liftIO $ bracket opennew hClose $ \h -> do
		retriever (encryptor basek) >>= sink h basep
		return True

	opennew = openBinaryFile dest WriteMode

	-- Open the file and seek to the start point in order to resume.
	openresume startpoint = do
		-- ReadWriteMode allows seeking; AppendMode does not.
		h <- openBinaryFile dest ReadWriteMode
		hSeek h AbsoluteSeek startpoint
		return h

{- Can resume when the chunk's offset is at or before the end of
 - the dest file. -}
resumeOffset :: Maybe Integer -> Key -> Maybe Integer
resumeOffset Nothing _ = Nothing
resumeOffset currsize k
	| offset <= currsize = offset
	| otherwise = Nothing
  where
	offset = chunkKeyOffset k

{- Drops chunks that are already present in a file, based on its size.
 - Keeps any non-chunk keys.
 -}
setupResume :: [[Key]] -> Integer -> [[Key]]
setupResume ls currsize = map dropunneeded ls
  where
	dropunneeded [] = []
	dropunneeded l@(k:_) = case keyChunkSize k of
		Just chunksize | chunksize > 0 ->
			genericDrop (currsize `div` chunksize) l
		_ -> l

{- Checks if a key is present in a remote. This requires any one
 - of the lists of options returned by chunkKeys to all check out
 - as being present using the checker action.
 -}
hasKeyChunks
	:: (Key -> Annex (Either String Bool))
	-> UUID
	-> ChunkConfig
	-> EncKey
	-> Key
	-> Annex (Either String Bool)
hasKeyChunks checker u chunkconfig encryptor basek
	| noChunks chunkconfig =
		-- Optimisation: Try the unchunked key first, to avoid
		-- looking in the git-annex branch for chunk counts
		-- that are likely not there.
		ifM ((Right True ==) <$> checker (encryptor basek))
			( return (Right True)
			, checklists impossible =<< chunkKeysOnly u basek
			)
	| otherwise = checklists impossible =<< chunkKeys u chunkconfig basek
  where
	checklists lastfailmsg [] = return $ Left lastfailmsg
	checklists _ (l:ls)
		| not (null l) = do
			v <- checkchunks l
			case v of
				Left e -> checklists e ls
				Right True -> return (Right True)
				Right False
					| null ls -> return (Right False)
					| otherwise -> checklists impossible ls
		| otherwise = checklists impossible ls
	
	checkchunks :: [Key] -> Annex (Either String Bool)
	checkchunks [] = return (Right True)
	checkchunks (k:ks) = do
		v <- checker (encryptor k)
		if v == Right True
			then checkchunks ks
			else return v

	impossible = "no recorded chunks"

{- A key can be stored in a remote unchunked, or as a list of chunked keys.
 - This can be the case whether or not the remote is currently configured
 - to use chunking.
 -
 - It's even possible for a remote to have the same key stored multiple
 - times with different chunk sizes!
 -
 - This finds all possible lists of keys that might be on the remote that
 - can be combined to get back the requested key, in order from most to
 - least likely to exist.
 -}
chunkKeys :: UUID -> ChunkConfig -> Key -> Annex [[Key]]
chunkKeys u chunkconfig k = do
	l <- chunkKeysOnly u k
	return $ if noChunks chunkconfig
		then [k] : l
		else l ++ [[k]]

chunkKeysOnly :: UUID -> Key -> Annex [[Key]]
chunkKeysOnly u k = map (toChunkList k) <$> getCurrentChunks u k

toChunkList :: Key -> (ChunkSize, ChunkCount) -> [Key]
toChunkList k (chunksize, chunkcount) = takeChunkKeyStream chunkcount $
	chunkKeyStream k chunksize
