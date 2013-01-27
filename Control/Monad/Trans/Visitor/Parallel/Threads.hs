-- Language extensions {{{
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UnicodeSyntax #-}
-- }}}

module Control.Monad.Trans.Visitor.Parallel.Threads where

-- Imports {{{
import Control.Applicative (Applicative,(<$>))
import Control.Concurrent (forkIO,killThread)
import Control.Monad (forever,forM_,mapM_,replicateM_)
import Control.Monad.CatchIO (MonadCatchIO)
import Control.Monad.IO.Class (MonadIO,liftIO)
import Control.Monad.State.Class (MonadState,StateType)
import Control.Monad.Trans.Reader (ask,runReaderT)
import Control.Monad.Trans.State.Strict (StateT,evalStateT)

import Data.Accessor.Monad.TF.State ((%=),(%:),get,getAndModify)
import Data.Accessor.Template (deriveAccessors)
import Data.IntMap (IntMap)
import qualified Data.IntMap as IntMap
import Data.Maybe (fromMaybe)
import Data.Monoid (Monoid(mempty))
import Data.PSQueue (Binding((:->)),PSQ)
import qualified Data.PSQueue as PSQ
import qualified Data.Set as Set
import Data.Word (Word64)

import qualified System.Log.Logger as Logger

import Control.Monad.Trans.Visitor
import Control.Monad.Trans.Visitor.Checkpoint
import Control.Monad.Trans.Visitor.Supervisor
import Control.Monad.Trans.Visitor.Supervisor.RequestQueue
import qualified Control.Monad.Trans.Visitor.Supervisor.RequestQueue.Monad as RQM
import Control.Monad.Trans.Visitor.Worker
import Control.Monad.Trans.Visitor.Workload
-- }}}

-- Types {{{

type WorkerId = Int

type RemovalPriority = Word64

data WorkgroupState result = WorkgroupState -- {{{
    {   active_workers_ :: !(IntMap (VisitorWorkerEnvironment result))
    ,   next_worker_id_ :: !WorkerId
    ,   next_priority_ :: !RemovalPriority
    ,   removal_queue_ :: !(PSQ WorkerId RemovalPriority)
    }
$( deriveAccessors ''WorkgroupState )
-- }}}

type WorkgroupStateMonad result = StateT (WorkgroupState result) IO

type WorkgroupRequestQueue result = RequestQueue result WorkerId (WorkgroupStateMonad result)

type WorkgroupMonad result = VisitorSupervisorMonad result WorkerId (WorkgroupStateMonad result)

data TerminationReason result = -- {{{
    Completed result
  | Aborted (VisitorProgress result)
  | Failure String
-- }}}

newtype WorkgroupControllerMonad result α = C { unwrapC :: RequestQueueReader result WorkerId (WorkgroupStateMonad result) α} deriving (Applicative,Functor,Monad,MonadCatchIO,MonadIO)
-- }}}

-- Instances {{{

instance Monoid result ⇒ RQM.RequestQueueMonad (WorkgroupControllerMonad result) where -- {{{
    type RequestQueueMonadResult (WorkgroupControllerMonad result) = result
    abort = C ask >>= abort
    getCurrentProgressAsync callback = C (ask >>= flip getCurrentProgressAsync callback)
    getNumberOfWorkersAsync callback = C (ask >>= flip getNumberOfWorkersAsync callback)
    requestProgressUpdateAsync callback = C (ask >>= flip requestProgressUpdateAsync callback)
-- }}}

-- }}}

-- Exposed Functions {{{

changeNumberOfWorkers :: -- {{{
    Monoid result ⇒
    (Int → IO Int) →
    WorkgroupControllerMonad result Int
changeNumberOfWorkers = RQM.syncAsync . changeNumberOfWorkersAsync
-- }}}

changeNumberOfWorkersAsync :: -- {{{
    Monoid result ⇒
    (Int → IO Int) →
    (Int → IO ()) →
    WorkgroupControllerMonad result ()
changeNumberOfWorkersAsync computeNewNumberOfWorkers receiveNewNumberOfWorkers = C $ ask >>= (flip enqueueRequest $ do
    old_number_of_workers ← numberOfWorkers
    new_number_of_workers ← liftIO $ computeNewNumberOfWorkers old_number_of_workers
    case new_number_of_workers `compare` old_number_of_workers of
        GT → replicateM_ (new_number_of_workers - old_number_of_workers) hireAWorker
        LT → replicateM_ (old_number_of_workers - new_number_of_workers) fireAWorker
        EQ → return ()
    liftIO . receiveNewNumberOfWorkers $ new_number_of_workers
 )
-- }}}

runVisitorIO :: -- {{{
    Monoid result ⇒
    (TerminationReason result → IO ()) →
    VisitorIO result →
    WorkgroupControllerMonad result α →
    IO α
runVisitorIO = runVisitorIOStartingFrom mempty
-- }}}

runVisitorIOStartingFrom :: -- {{{
    Monoid result ⇒
    VisitorProgress result →
    (TerminationReason result → IO ()) →
    VisitorIO result →
    WorkgroupControllerMonad result α →
    IO α
runVisitorIOStartingFrom starting_progress notifyFinished =
    genericRunVisitorStartingFrom starting_progress notifyFinished
    .
    flip forkVisitorIOWorkerThread
-- }}}

runVisitorT :: -- {{{
    (Monoid result, MonadIO m) ⇒
    (∀ α. m α → IO α) →
    (TerminationReason result → IO ()) →
    VisitorT m result →
    WorkgroupControllerMonad result α →
    IO α
runVisitorT = runVisitorTStartingFrom mempty
-- }}}

runVisitorTStartingFrom :: -- {{{
    (Monoid result, MonadIO m) ⇒
    VisitorProgress result →
    (∀ α. m α → IO α) →
    (TerminationReason result → IO ()) →
    VisitorT m result →
    WorkgroupControllerMonad result α →
    IO α
runVisitorTStartingFrom starting_progress runMonad notifyFinished =
    genericRunVisitorStartingFrom starting_progress notifyFinished
    .
    flip (forkVisitorTWorkerThread runMonad)
-- }}}

runVisitor :: -- {{{
    Monoid result ⇒
    (TerminationReason result → IO ()) →
    Visitor result →
    WorkgroupControllerMonad result α →
    IO α
runVisitor = runVisitorStartingFrom mempty
-- }}}

runVisitorStartingFrom :: -- {{{
    Monoid result ⇒
    VisitorProgress result →
    (TerminationReason result → IO ()) →
    Visitor result →
    WorkgroupControllerMonad result α →
    IO α
runVisitorStartingFrom starting_progress notifyFinished =
    genericRunVisitorStartingFrom starting_progress notifyFinished
    .
    flip forkVisitorWorkerThread
-- }}}

-- }}}

-- Logging Functions {{{
logger_name = "Threads"

debugM, infoM :: MonadIO m ⇒ String → m ()
debugM = liftIO . Logger.debugM logger_name
infoM = liftIO . Logger.infoM logger_name
-- }}}

-- Internal Functions {{{

applyToSelectedActiveWorkers :: -- {{{
    Monoid result ⇒
    (WorkerId → VisitorWorkerEnvironment result → WorkgroupStateMonad result ()) →
    [WorkerId] →
    WorkgroupStateMonad result ()
applyToSelectedActiveWorkers action worker_ids = do
    workers ← get active_workers
    forM_ worker_ids $ \worker_id →
        maybe (return ()) (action worker_id) (IntMap.lookup worker_id workers)
-- }}}

bumpWorkerRemovalPriority :: -- {{{
    (MonadState m, StateType m ~ WorkgroupState result) ⇒
    WorkerId →
    m ()
bumpWorkerRemovalPriority worker_id =
    getAndModify next_priority pred >>= (removal_queue %:) . PSQ.insert worker_id
-- }}}

constructWorkgroupActions :: -- {{{
    Monoid result ⇒
    WorkgroupRequestQueue result →
    ((VisitorWorkerTerminationReason result → IO ()) → VisitorWorkload → IO (VisitorWorkerEnvironment result)) →
    VisitorSupervisorActions result WorkerId (WorkgroupStateMonad result)
constructWorkgroupActions request_queue spawnWorker = VisitorSupervisorActions
    {   broadcast_progress_update_to_workers_action =
            applyToSelectedActiveWorkers $ \worker_id (VisitorWorkerEnvironment{workerPendingRequests}) → liftIO $
                sendProgressUpdateRequest workerPendingRequests $ enqueueRequest request_queue . receiveProgressUpdate worker_id
    ,   broadcast_workload_steal_to_workers_action =
            applyToSelectedActiveWorkers $ \worker_id (VisitorWorkerEnvironment{workerPendingRequests}) → liftIO $
                sendWorkloadStealRequest workerPendingRequests $ enqueueRequest request_queue . receiveStolenWorkload worker_id
    ,   receive_current_progress_action = receiveProgress request_queue
    ,   send_workload_to_worker_action = \workload worker_id → do
            infoM $ "Spawning worker " ++ show worker_id ++ " with workload " ++ show workload
            environment ← liftIO $ spawnWorker (enqueueRequest request_queue . receiveTerminationReason worker_id) workload
            active_workers %: IntMap.insert worker_id environment
            bumpWorkerRemovalPriority worker_id
    }
  where
    receiveTerminationReason worker_id (VisitorWorkerFinished final_progress) = do
        remove_worker ← IntMap.notMember worker_id <$> get active_workers
        infoM $ if remove_worker
            then "Worker " ++ show worker_id ++ " has finished, and will be removed."
            else "Worker " ++ show worker_id ++ " has finished, and will look for another workload."
        receiveWorkerFinishedWithRemovalFlag remove_worker worker_id final_progress
    receiveTerminationReason worker_id (VisitorWorkerFailed exception) =
        receiveWorkerFailure worker_id (show exception)
    receiveTerminationReason worker_id VisitorWorkerAborted = do
        infoM $ "Worker " ++ show worker_id ++ " has been aborted."
        removeWorker worker_id
-- }}}

fireAWorker :: -- {{{
    Monoid result ⇒
    WorkgroupMonad result ()
fireAWorker =
    Set.minView <$> getWaitingWorkers
    >>= \x → case x of
        Just (worker_id,_) → do
            infoM $ "Removing waiting worker " ++ show worker_id ++ "."
            removeWorker worker_id
            removeWorkerFromRemovalQueue worker_id
        Nothing → do
            (worker_id,new_removal_queue) ← do
                (PSQ.minView <$> get removal_queue) >>=
                    \x → case x of
                        Nothing → error "No workers found to be removed!"
                        Just (worker_id :-> _,rest_queue) → return (worker_id,rest_queue)
            infoM $ "Removing active worker " ++ show worker_id ++ "."
            removal_queue %= new_removal_queue
            VisitorWorkerEnvironment{workerPendingRequests} ←
                fromMaybe (error $ "Active worker " ++ show worker_id ++ " not found in the map of active workers!")
                <$>
                IntMap.lookup worker_id
                <$>
                get active_workers
            active_workers %: IntMap.delete worker_id
            liftIO $ sendAbortRequest workerPendingRequests
-- }}}

genericRunVisitorStartingFrom :: -- {{{
    Monoid result ⇒
    VisitorProgress result →
    (TerminationReason result → IO ()) →
    ((VisitorWorkerTerminationReason result → IO ()) → VisitorWorkload → IO (VisitorWorkerEnvironment result)) →
    WorkgroupControllerMonad result α →
    IO α
genericRunVisitorStartingFrom starting_progress notifyFinished spawnWorker (C controller) = do
    request_queue ← newRequestQueue
    forkIO $
        (flip evalStateT initial_state $ do
            VisitorSupervisorResult termination_reason _ ←
                runVisitorSupervisor (constructWorkgroupActions request_queue spawnWorker) $
                    -- enableSupervisorDebugMode >>
                    forever (processRequest request_queue)
            (IntMap.elems <$> get active_workers)
                >>= mapM_ (liftIO . killThread . workerThreadId)
            return $ case termination_reason of
                SupervisorAborted remaining_progress → Aborted remaining_progress
                SupervisorCompleted result → Completed result
                SupervisorFailure worker_id message →
                    Failure $ "Thread " ++ show worker_id ++ " failed with message: " ++ message
        ) >>= notifyFinished
    runReaderT controller request_queue 
  where
    initial_state =
        WorkgroupState
            {   active_workers_ = mempty
            ,   next_worker_id_ = 0
            ,   next_priority_ = maxBound
            ,   removal_queue_ = PSQ.empty
            }
-- }}}

hireAWorker :: -- {{{
    Monoid result ⇒
    WorkgroupMonad result ()
hireAWorker = do
    worker_id ← getAndModify next_worker_id succ
    infoM $ "Adding worker " ++ show worker_id
    bumpWorkerRemovalPriority worker_id
    addWorker worker_id
-- }}}

numberOfWorkers :: WorkgroupMonad result Int -- {{{
numberOfWorkers = PSQ.size <$> get removal_queue
-- }}}

removeWorkerFromRemovalQueue :: WorkerId → WorkgroupMonad result () -- {{{
removeWorkerFromRemovalQueue = (removal_queue %:) . PSQ.delete
-- }}}

-- }}}
