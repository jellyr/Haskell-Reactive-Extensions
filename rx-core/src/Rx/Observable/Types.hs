{-# LANGUAGE DeriveDataTypeable #-}
module Rx.Observable.Types where

import Data.Typeable (Typeable)

import Control.Exception (Exception(..), throwIO)
import Control.Monad (forever)

import Control.Exception   (AsyncException (ThreadKilled), Handler (..),
                            SomeException, catches, throw)

import Control.Concurrent.STM (TChan, atomically, readTChan)

import           Rx.Disposable ( Disposable, emptyDisposable
                               , newCompositeDisposable
                               , newSingleAssignmentDisposable )
import qualified Rx.Disposable as Disposable

import           Rx.Scheduler  ( Async, IScheduler, Sync
                               , currentThread, newThread, schedule )

--------------------------------------------------------------------------------

class IObserver observer where
  onNext :: observer v -> v -> IO ()
  onNext ob v = emitNotification ob (OnNext v)

  onError :: observer v -> SomeException -> IO ()
  onError ob err = emitNotification ob (OnError err)

  onCompleted :: observer v -> IO ()
  onCompleted ob = emitNotification ob OnCompleted

  emitNotification :: observer v -> Notification v -> IO ()

class ToObserver observer where
  toObserver :: observer a -> Observer a

class IObservable observable where
  onSubscribe :: observable s a -> Observer a -> IO Disposable

class ToAsyncObservable observable where
  toAsyncObservable :: observable a -> Observable Async a

class ToSyncObservable observable where
  toSyncObservable :: observable a -> Observable Sync a

--------------------------------------------------------------------------------

data Notification v
  = OnNext v
  | OnError SomeException
  | OnCompleted
  deriving (Show, Typeable)

data Subject v =
  Subject {
    _subjectOnSubscribe        :: Observer v -> IO Disposable
  , _subjectOnEmitNotification :: Notification v -> IO ()
  }
  deriving (Typeable)

newtype Observer v
  = Observer (Notification v -> IO ())
  deriving (Typeable)


newtype Observable s a =
  Observable { _onSubscribe :: Observer a -> IO Disposable }

data TimeoutError
  = TimeoutError
  deriving (Show, Typeable)

instance Exception TimeoutError

--------------------------------------------------------------------------------

instance ToObserver Subject where
  toObserver subject = Observer (_subjectOnEmitNotification subject)

instance ToAsyncObservable Subject where
  toAsyncObservable = Observable . _subjectOnSubscribe

instance IObserver Subject where
  emitNotification = _subjectOnEmitNotification

instance ToObserver Observer where
  toObserver = id

instance IObserver Observer where
  emitNotification (Observer f) = f

instance IObservable Observable where
  onSubscribe = _onSubscribe

instance ToAsyncObservable TChan where
  toAsyncObservable chan = Observable $ \observer ->
    schedule newThread $ forever $ do
      ev <- atomically $ readTChan chan
      onNext observer ev

instance ToSyncObservable TChan where
  toSyncObservable chan = Observable $ \observer -> do
    forever $ do
      ev <- atomically $ readTChan chan
      onNext observer ev
    emptyDisposable

--------------------------------------------------------------------------------

unsafeSubscribe :: (IObservable observable)
          => observable s v
          -> (v -> IO ())
          -> (SomeException -> IO ())
          -> IO ()
          -> IO Disposable
unsafeSubscribe source nextHandler errHandler complHandler =
    onSubscribe source $ Observer observerFn
  where
    observerFn (OnNext v) = nextHandler v
    observerFn (OnError err) = errHandler err
    observerFn OnCompleted = complHandler

subscribe :: (IObservable observable)
          => observable s v
          -> (v -> IO ())
          -> (SomeException -> IO ())
          -> IO ()
          -> IO Disposable
subscribe source nextHandler0 errHandler0 complHandler0 =
    unsafeSubscribe source nextHandler errHandler0 complHandler0
  where
    nextHandler v =
      (v `seq` nextHandler0 v)
        `catches` [ Handler (\err@ThreadKilled -> throw err)
                  , Handler errHandler0]


subscribeOnNext :: (IObservable observable)
                => observable s v
                -> (v -> IO ())
                -> IO Disposable
subscribeOnNext source nextHandler =
  subscribe source nextHandler throwIO (return ())

subscribeObserver
  :: (IObservable observable, ToObserver observer)
  => observable s a -> observer a -> IO Disposable
subscribeObserver source observer0 =
  let observer = toObserver observer0
  in subscribe source
               (onNext observer)
               (onError observer)
               (onCompleted observer)

--------------------------------------------------------------------------------

createObservable :: IScheduler scheduler
                 => scheduler s
                 -> (Observer a -> IO Disposable)
                 -> Observable s a
createObservable scheduler action = Observable $ \observer -> do
  obsDisposable    <- newCompositeDisposable
  actionDisposable <- newSingleAssignmentDisposable
  threadDisposable <-
    schedule scheduler $ action observer >>=
      flip Disposable.set actionDisposable

  Disposable.append threadDisposable obsDisposable
  Disposable.append actionDisposable obsDisposable

  return $ Disposable.toDisposable obsDisposable