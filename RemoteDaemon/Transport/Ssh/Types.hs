{- git-remote-daemon, git-annex-shell notifychanges protocol types
 -
 - Copyright 2014 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

{-# LANGUAGE TypeSynonymInstances, FlexibleInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module RemoteDaemon.Transport.Ssh.Types (
	Notification(..),
	Proto.serialize,
	Proto.deserialize,
	Proto.formatMessage,
) where

import qualified Utility.SimpleProtocol as Proto
import RemoteDaemon.Types (RefList)

data Notification
	= READY
	| CHANGED RefList

instance Proto.Sendable Notification where
	formatMessage READY = ["READY"]
	formatMessage (CHANGED shas) = ["CHANGED", Proto.serialize shas]

instance Proto.Receivable Notification where
	parseCommand "READY" = Proto.parse0 READY
	parseCommand "CHANGED" = Proto.parse1 CHANGED
	parseCommand _ = Proto.parseFail
