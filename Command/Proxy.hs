{- git-annex command
 -
 - Copyright 2014 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Command.Proxy where

import Common.Annex
import Command
import Config
import Utility.Tmp
import Utility.Env
import Annex.Direct
import qualified Git.Branch
import qualified Git.Sha

cmd :: [Command]
cmd = [notBareRepo $
	command "proxy" ("-- git command") seek
		SectionPlumbing "safely bypass direct mode guard"]

seek :: CommandSeek
seek = withWords start

start :: [String] -> CommandStart
start [] = error "Did not specify command to run."
start (c:ps) = liftIO . exitWith =<< ifM isDirect
	( do
		g <- gitRepo
		withTmpDirIn (gitAnnexTmpMiscDir g) "proxy" go
	, liftIO $ safeSystem c (map Param ps)
	)
  where
	go tmp = do
		oldref <- fromMaybe Git.Sha.emptyTree
			<$> inRepo Git.Branch.currentSha
		exitcode <- liftIO $ proxy tmp
		mergeDirectCleanup tmp oldref
		return exitcode
	proxy tmp = do
		usetmp <- Just . addEntry "GIT_WORK_TREE" tmp  <$> getEnvironment
		unlessM (boolSystemEnv "git" [Param "checkout", Param "--", Param "."] usetmp) $
			error "Failed to set up proxy work tree."
		safeSystemEnv c (map Param ps) usetmp
