-- Language extensions {{{
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UnicodeSyntax #-}
-- }}}

module Control.Monad.Trans.Visitor.Main -- {{{
    ( TerminationReason(..)
    , mainVisitor
    , mainVisitorIO
    , mainVisitorT
    ) where -- }}}

-- Imports {{{
import Prelude hiding (readFile,writeFile)

import Control.Concurrent (ThreadId,killThread,threadDelay)
import Control.Exception (finally,handleJust,onException)
import Control.Monad (forever,liftM)
import Control.Monad.IO.Class (MonadIO(..))
import Control.Monad.Tools (ifM)

import Data.ByteString.Lazy (readFile,writeFile)
import Data.Char (toUpper)
import Data.Composition ((.*))
import Data.Either.Unwrap (mapRight)
import Data.Maybe (catMaybes)
import Data.Monoid (Monoid(..))
import Data.Serialize (Serialize,decodeLazy,encodeLazy)

import Options.Applicative

import System.Directory (doesFileExist,removeFile,renameFile)
import System.IO.Error (isDoesNotExistError)
import System.Log (Priority(WARNING))
import qualified System.Log.Logger as Logger
import System.Log.Logger (setLevel,rootLoggerName,updateGlobalLogger)

import Control.Monad.Trans.Visitor (Visitor,VisitorIO,VisitorT)
import Control.Monad.Trans.Visitor.Checkpoint
import Control.Monad.Trans.Visitor.Supervisor.Driver
import Control.Monad.Trans.Visitor.Supervisor.RequestQueue
-- }}}

-- Exposed {{{

mainVisitor :: -- {{{
    (Monoid result, Serialize result, MonadIO result_monad) ⇒
    Driver result_monad result →
    Parser α →
    (TerminationReason result → IO ()) →
    (α → Visitor result) →
    result_monad ()
mainVisitor Driver{..} = genericMain driverRunVisitor
-- }}}

mainVisitorIO :: -- {{{
    (Monoid result, Serialize result, MonadIO result_monad) ⇒
    Driver result_monad result →
    Parser α →
    (TerminationReason result → IO ()) →
    (α → VisitorIO result) →
    result_monad ()
mainVisitorIO Driver{..} = genericMain driverRunVisitorIO
-- }}}

mainVisitorT :: -- {{{
    (Monoid result, Serialize result, MonadIO result_monad, Functor m, MonadIO m) ⇒
    Driver result_monad result →
    (∀ β. m β → IO β) →
    Parser α →
    (TerminationReason result → IO ()) →
    (α → VisitorT m result) →
    result_monad ()
mainVisitorT Driver{..} = genericMain . driverRunVisitorT
-- }}}

-- }}}

-- Internal {{{

-- Types {{{
data CheckpointConfiguration = CheckpointConfiguration -- {{{
    {   checkpoint_path :: FilePath
    ,   checkpoint_interval :: Float
    } deriving (Eq,Show)
-- }}}

data LoggingConfiguration = LoggingConfiguration -- {{{
    {   log_level :: Priority
    } deriving (Eq,Show)
-- }}}

data Configuration = Configuration -- {{{
    {   maybe_configuration_checkpoint :: Maybe CheckpointConfiguration
    ,   configuration_logging :: LoggingConfiguration
    } deriving (Eq,Show)
-- }}}
-- }}}

-- Options {{{
checkpoint_configuration_options :: Parser (Maybe CheckpointConfiguration) -- {{{
checkpoint_configuration_options =
    maybe (const Nothing) (Just .* CheckpointConfiguration)
        <$> nullOption
            (   long "checkpoint-file"
             <> metavar "FILE"
             <> short 'c'
             <> help "Path to the checkpoint file;  enables periodic checkpointing"
             <> reader (Right . Just)
             <> value Nothing
            )
        <*> option
            (   long "checkpoint-interval"
             <> metavar "SECONDS"
             <> short 'i'
             <> help "Time between checkpoints (in seconds, decimals allowed);  ignored if checkpoint file not specified"
             <> value 60
             <> showDefault
            )
-- }}}

logging_configuration_options :: Parser LoggingConfiguration -- {{{
logging_configuration_options =
    LoggingConfiguration
        <$> nullOption
            (   long "log-level"
             <> metavar "LEVEL"
             <> short 'l'
             <> help "Upper bound (inclusive) on the importance of the messages that will be logged;  must be one of (in increasing order of importance): DEBUG, INFO, NOTICE, WARNING, ERROR, CRITICAL, ALERT, EMERGENCY"
             <> value WARNING
             <> showDefault
             <> reader (auto . map toUpper)
            )
-- }}}


configuration_options :: Parser Configuration -- {{{
configuration_options =
    Configuration
        <$> checkpoint_configuration_options
        <*> logging_configuration_options
-- }}}
-- }}}

-- Logging {{{
debugM :: MonadIO m ⇒ String → m ()
debugM = liftIO . Logger.debugM "Main"

infoM :: MonadIO m ⇒ String → m ()
infoM = liftIO . Logger.infoM "Main"

noticeM :: MonadIO m ⇒ String → m ()
noticeM = liftIO . Logger.noticeM "Main"
-- }}}

-- Utilities {{{
maybeForkIO :: RequestQueueMonad m ⇒ (α → m ()) → Maybe α → m (Maybe ThreadId) -- {{{
maybeForkIO loop = maybe (return Nothing) (liftM Just . fork . loop)
-- }}}

removeFileIfExists :: FilePath → IO () -- {{{
removeFileIfExists path =
    handleJust
        (\e → if isDoesNotExistError e then Nothing else Just ())
        (\_ → return ())
        (removeFile path)
-- }}}
-- }}}

-- Loops {{{
checkpointLoop :: (RequestQueueMonad m, Serialize (RequestQueueMonadResult m)) ⇒ CheckpointConfiguration → m α -- {{{
checkpointLoop CheckpointConfiguration{..} = forever $ do
    liftIO $ threadDelay delay
    checkpoint ← requestProgressUpdate
    noticeM $ "Writing checkpoint file"
    liftIO $
        (do writeFile checkpoint_temp_path (encodeLazy checkpoint)
            renameFile checkpoint_temp_path checkpoint_path
        ) `onException` (
            removeFileIfExists checkpoint_path
        )
  where
    checkpoint_temp_path = checkpoint_path ++ ".tmp"
    delay = round $ checkpoint_interval * 1000000
-- }}}

managerLoop :: (RequestQueueMonad m, Serialize (RequestQueueMonadResult m)) ⇒ Configuration → m () -- {{{
managerLoop Configuration{..} = do
    maybe_checkpoint_thread_id ← maybeForkIO checkpointLoop maybe_configuration_checkpoint
    case catMaybes
        [maybe_checkpoint_thread_id
        ]
     of [] → return ()
        thread_ids → liftIO $
            (forever $ threadDelay 3600000000)
            `finally`
            (mapM_ killThread thread_ids)
-- }}}
-- }}}

-- Main functions {{{

genericMain :: -- {{{
    ( result ~ RequestQueueMonadResult manager_monad
    , RequestQueueMonad manager_monad
    , Serialize result
    , MonadIO result_monad
    ) ⇒
    (
        IO (Maybe (VisitorProgress result)) →
        (TerminationReason result → IO ()) →
        visitor →
        manager_monad () →
        result_monad ()
    ) →
    Parser α →
    (TerminationReason result → IO ()) →
    (α → visitor) →
    result_monad ()
genericMain run visitor_configuration_options notifyTerminated constructVisitorFromConfiguration =
    liftIO (execParser (info (liftA2 (,) configuration_options visitor_configuration_options) mempty))
    >>=
    \(configuration@Configuration{..},visitor_configuration) → do
        let LoggingConfiguration{..} = configuration_logging
        liftIO $ updateGlobalLogger rootLoggerName (setLevel log_level)
        case maybe_configuration_checkpoint of
            Nothing → do
                infoM $ "Checkpointing is NOT enabled"
                run (return Nothing)
                    notifyTerminated
                    (constructVisitorFromConfiguration visitor_configuration)
                    (managerLoop configuration)
            Just CheckpointConfiguration{..} → do
                noticeM $ "Checkpointing enabled"
                noticeM $ "Checkpoint file is " ++ checkpoint_path
                noticeM $ "Checkpoint interval is " ++ show checkpoint_interval ++ " seconds"
                run (ifM (doesFileExist checkpoint_path)
                        (noticeM "Loading existing checkpoint file" >> either error Just . decodeLazy <$> readFile checkpoint_path)
                        (return Nothing)
                    )
                    ((>> (noticeM "Deleting checkpoint file" >> removeFileIfExists checkpoint_path)) . notifyTerminated)
                    (constructVisitorFromConfiguration visitor_configuration)
                    (managerLoop configuration)
-- }}}

-- }}}

-- }}}