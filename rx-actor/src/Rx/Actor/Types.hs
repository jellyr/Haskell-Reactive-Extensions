{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE ExistentialQuantification #-}
module Rx.Actor.Types where

import Control.Concurrent (ThreadId)
import Control.Concurrent.Async (Async)
import Control.Concurrent.STM (TVar, TChan, newTChanIO)

import Control.Exception (Exception, SomeException)

import Control.Applicative (Applicative, (<$>), (<*>))
import Control.Monad.Trans (MonadIO(..))
import Control.Monad.State.Strict (StateT)

import qualified Control.Monad.State.Strict as State

import Data.Typeable (Typeable, cast)
import Data.HashMap.Strict (HashMap)
import Data.Maybe (fromMaybe)

import Tiempo (TimeInterval)

import Rx.Disposable ( Disposable, IDisposable, ToDisposable
                     , dispose )
import Rx.Subject (Subject)
import Rx.Observable (IObserver(..), Observable, Sync)

import qualified Rx.Disposable as Disposable

--------------------------------------------------------------------------------

data GenericEvent = forall a . Typeable a => GenericEvent a

data RestartDirective
  = Stop
  | Resume
  | Raise
  | Restart
  | RestartOne
  deriving (Show, Eq, Ord, Typeable)

data ActorEvent
  = NormalEvent GenericEvent
  | RestartActorEvent !SomeException !GenericEvent
  | StopActorEvent
  deriving (Typeable)


newtype ActorM st a
  = ActorM { fromActorM :: StateT (st, EventBus) IO a }
  deriving (Functor, Applicative, Monad, MonadIO, Typeable)

type ActorKeyVal = String
type ActorKey = Maybe ActorKeyVal
type EventBus = Subject GenericEvent
type EventBusDecorator =
  Observable Sync ActorEvent -> Observable Sync ActorEvent
type AttemptCount = Int

data InitResult st
  = InitOk st
  | InitFailure SomeException
  deriving (Show, Typeable)

instance Functor InitResult where
  fmap f (InitOk s) = InitOk (f s)
  fmap _ (InitFailure err) = InitFailure err

data EventHandler st
  = forall t . Typeable t => EventHandler String (t -> ActorM st ())

data ErrorHandler st
  = forall e . (Typeable e, Exception e) => ErrorHandler (e -> st -> IO RestartDirective)

class IActor actor where
  getActorKey :: actor -> String

data ActorDef st
  = ActorDef {
    _actorChildKey          :: !ActorKey
  , _actorForker            :: !(IO () -> IO ThreadId)
  , _actorPreStart          :: EventBus -> IO (InitResult st)
  , _actorPostStop          :: !(st -> IO ())
  , _actorPreRestart        :: !(st -> SomeException -> GenericEvent -> IO ())
  , _actorPostRestart
      :: !(st -> SomeException -> GenericEvent -> IO (InitResult st))
  , _actorRestartDirective  :: !(HashMap String (ErrorHandler st))
  , _actorDelayAfterStart   :: !TimeInterval
  , _actorReceive           :: !(HashMap String (EventHandler st))
  , _actorRestartAttempt    :: !Int
  , _actorEventBusDecorator :: !(EventBusDecorator)
  }
  deriving (Typeable)

instance IActor (ActorDef st) where
  getActorKey actor =
    fromMaybe (error "FATAL: getActorKey: Actor must have an actor key")
              (_actorChildKey actor)

data GenericActorDef = forall st . GenericActorDef (ActorDef st)

instance IActor GenericActorDef where
  getActorKey (GenericActorDef actorDef) = getActorKey actorDef

data Actor
  = Actor {
    _actorQueue            :: !(TChan GenericEvent)
  , _actorCtrlQueue        :: !(TChan ActorEvent)
  , _actorCleanup          :: !Disposable
  , _actorDef              :: !GenericActorDef
  , _actorEventBus         :: !EventBus
  }
  deriving (Typeable)

instance IActor Actor where
  getActorKey = getActorKey . _actorDef

instance ToDisposable Actor where
  toDisposable = Disposable.toDisposable . _actorCleanup

instance IDisposable Actor where
  dispose = Disposable.dispose . Disposable.toDisposable
  isDisposed = Disposable.isDisposed . Disposable.toDisposable

--------------------------------------------------------------------------------

data SpawnInfo
  = NewActor {
    _spawnActorDef   :: !GenericActorDef
  }
  | forall st . RestartActor {
    _spawnQueue       :: !(TChan GenericEvent)
  , _spawnCtrlQueue   :: !(TChan ActorEvent)
  , _spawnPrevState   :: !st
  , _spawnError       :: !SomeException
  , _spawnFailedEvent :: !GenericEvent
  , _spawnActorDef    :: !GenericActorDef
  , _spawnDelay       :: !TimeInterval
  }
  deriving (Typeable)

data SupervisionEvent
  = ActorSpawned { _supEvInitActorDef :: !GenericActorDef }
  | ActorTerminated {
      _supEvTerminatedActorDef :: !GenericActorDef
    }
  | forall st . ActorFailedWithError {
      _supEvTerminatedState       :: !st
    , _supEvTerminatedFailedEvent :: !GenericEvent
    , _supEvTerminatedError       :: !SomeException
    , _supEvTerminatedActor       :: !Actor
    , _supEvTerminatedDirective   :: !RestartDirective
    }
  | ActorFailedOnInitialize {
      _supEvTerminatedError :: !SomeException
    , _supEvTerminatedActor :: !Actor
    }
  deriving (Typeable)

instance Show SupervisionEvent where
  show (ActorSpawned gActorDef) =
    "ActorSpawned " ++ getActorKey gActorDef
  show (ActorTerminated gActorDef) =
    "ActorTerminated " ++ getActorKey gActorDef
  show supEv@(ActorFailedWithError {}) =
    let actorKey = getActorKey . _actorDef $ _supEvTerminatedActor supEv
        actorErr = _supEvTerminatedError supEv
    in "ActorFailedWithError " ++ actorKey ++ " " ++ show actorErr
  show supEv@(ActorFailedOnInitialize {}) =
    let actorKey = getActorKey . _actorDef $ _supEvTerminatedActor supEv
        actorErr = _supEvTerminatedError supEv
    in "ActorFailedOnInitialize " ++ actorKey ++ " " ++ show actorErr

instance Exception SupervisionEvent

data SupervisorStrategy
  = OneForOne
  | AllForOne
  deriving (Show, Eq, Ord, Typeable)

data SupervisorDef
  = SupervisorDef {
    _supervisorStrategy           :: !SupervisorStrategy
  , _supervisorBackoffDelayFn     :: !(AttemptCount -> TimeInterval)
  -- ^ TODO: Move this attribute to ActorDef
  , _supervisorMaxRestartAttempts :: !AttemptCount
  , _supervisorDefChildren        :: ![GenericActorDef]
  }
  deriving (Typeable)

data Supervisor
  = Supervisor {
    _supervisorDef        :: !SupervisorDef
  , _supervisorAsync      :: !(Async ())
  , _supervisorEventBus   :: !EventBus
  , _supervisorDisposable :: !Disposable
  , _supervisorChildren   :: !(TVar (HashMap ActorKeyVal Actor))
  , _sendToSupervisor     :: !(SupervisionEvent -> IO ())
  }
  deriving (Typeable)

instance IDisposable Supervisor where
  dispose = dispose . _supervisorDisposable
  isDisposed = Disposable.isDisposed . _supervisorDisposable

instance ToDisposable Supervisor where
  toDisposable = Disposable.toDisposable . _supervisorDisposable

--------------------------------------------------------------------------------

getRestartAttempts :: GenericActorDef -> Int
getRestartAttempts (GenericActorDef actorDef) = _actorRestartAttempt actorDef
{-# INLINE getRestartAttempts #-}

incRestartAttempt :: GenericActorDef -> IO GenericActorDef
incRestartAttempt (GenericActorDef actorDef) =
    return $ GenericActorDef
           $ actorDef { _actorRestartAttempt = succ restartAttempt }
  where
    restartAttempt = _actorRestartAttempt actorDef
{-# INLINE incRestartAttempt #-}


getRestartDelay :: GenericActorDef -> TimeInterval
getRestartDelay = error "TODO"

--------------------------------------------------------------------------------

createActorQueues :: SpawnInfo
                  -> IO (TChan GenericEvent, TChan ActorEvent)
createActorQueues (NewActor {}) = (,) <$> newTChanIO <*> newTChanIO
createActorQueues spawn@(RestartActor {}) =
  return (_spawnQueue spawn, _spawnCtrlQueue spawn)
