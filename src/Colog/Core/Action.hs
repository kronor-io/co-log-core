{-# LANGUAGE CPP                  #-}
{-# LANGUAGE DataKinds            #-}
{-# LANGUAGE Rank2Types           #-}
{-# LANGUAGE TypeFamilies         #-}
{-# LANGUAGE TypeOperators        #-}
{-# LANGUAGE UndecidableInstances #-}

{- |
Module                  : Colog.Core.Action
Copyright               : (c) 2018-2020 Kowainik, 2021-2022 Co-Log
SPDX-License-Identifier : MPL-2.0
Maintainer              : Co-Log <xrom.xkov@gmail.com>
Stability               : Stable
Portability             : Portable

Implements core data types and combinators for logging actions.
-}

module Colog.Core.Action
       ( -- * Core type and instances
         LogAction (..)
       , (<&)
       , (&>)

         -- * 'Semigroup' combinators
       , foldActions

         -- * Contravariant combinators
         -- $contravariant
       , cfilter
       , cfilterM
       , cmap
       , (>$<)
       , cmapMaybe
       , cmapMaybeM
       , (Colog.Core.Action.>$)
       , cmapM

         -- * Divisible combinators
         -- $divisible
       , divide
       , divideM
       , conquer
       , (>*<)
       , (>*)
       , (*<)

         -- * Decidable combinators
         -- $decidable
       , lose
       , choose
       , chooseM
       , (>|<)

         -- * Comonadic combinators
         -- $comonad
       , extract
       , extend
       , (=>>)
       , (<<=)
       , duplicate
       , multiplicate
       , separate

         -- * Higher-order combinators
       , hoistLogAction
       ) where

import Control.Monad (when, (<=<), (>=>))
import Data.Coerce (coerce)
import Data.Foldable (fold, for_, traverse_)
import Data.Kind (Constraint)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Monoid (Monoid (..))
import Data.Semigroup (Semigroup (..), stimesMonoid)
import Data.Void (Void, absurd)
import GHC.TypeLits (ErrorMessage (..), TypeError)

#if MIN_VERSION_base(4,12,0)
import qualified Data.Functor.Contravariant as Contravariant
#endif

{- $setup
>>> import Colog.Core.IO
-}

----------------------------------------------------------------------------
-- Core data type with instances
----------------------------------------------------------------------------

{- | Polymorphic and very general logging action type.

* @__msg__@ type variables is an input for logger. It can be 'Text' or custom
logging messsage with different fields that you want to format in future.

* @__m__@ type variable is for monadic action inside which logging is happening. It
can be either 'IO' or some custom pure monad.

Key design point here is that 'LogAction' is:

* 'Semigroup'
* 'Monoid'
* 'Data.Functor.Contravariant.Contravariant'
* 'Data.Functor.Contravariant.Divisible.Divisible'
* 'Data.Functor.Contravariant.Divisible.Decidable'
* 'Control.Comonad.Comonad'
-}
newtype LogAction m msg = LogAction
    { unLogAction :: msg -> m ()
    }

{- | This instance allows you to join multiple logging actions into single one.

For example, if you have two actions like these:

@
logToStdout :: 'LogAction' IO String  -- outputs String to terminal
logToFile   :: 'LogAction' IO String  -- appends String to some file
@

You can create new 'LogAction' that perform both actions one after another using 'Semigroup':

@
logToBoth :: 'LogAction' IO String  -- outputs String to both terminal and some file
logToBoth = logToStdout <> logToFile
@
-}
instance Applicative m => Semigroup (LogAction m a) where
    (<>) :: LogAction m a -> LogAction m a -> LogAction m a
    LogAction action1 <> LogAction action2 = LogAction $ \a -> action1 a *> action2 a
    {-# INLINE (<>) #-}

    sconcat :: NonEmpty (LogAction m a) -> LogAction m a
    sconcat = foldActions
    {-# INLINE sconcat #-}

    stimes :: Integral b => b -> LogAction m a -> LogAction m a
    stimes = stimesMonoid
    {-# INLINE stimes #-}

instance Applicative m => Monoid (LogAction m a) where
    mappend :: LogAction m a -> LogAction m a -> LogAction m a
    mappend = (<>)
    {-# INLINE mappend #-}

    mempty :: LogAction m a
    mempty = LogAction $ \_ -> pure ()
    {-# INLINE mempty #-}

    mconcat :: [LogAction m a] -> LogAction m a
    mconcat = foldActions
    {-# INLINE mconcat #-}

#if MIN_VERSION_base(4,12,0)
instance Contravariant.Contravariant (LogAction m) where
    contramap :: (a -> b) -> LogAction m b -> LogAction m a
    contramap = cmap
    {-# INLINE contramap #-}

    (>$) :: b -> LogAction m b -> LogAction m a
    (>$) = (Colog.Core.Action.>$)
    {-# INLINE (>$) #-}
#endif

-- | For tracking usage of unrepresentable class instances of 'LogAction'.
type family UnrepresentableClass :: Constraint
  where
    UnrepresentableClass = TypeError
        ( 'Text "'LogAction' cannot have a 'Functor' instance by design."
        ':$$: 'Text "However, you've attempted to use this instance."
#if MIN_VERSION_base(4,12,0)
        ':$$: 'Text ""
        ':$$: 'Text "Probably you meant 'Contravariant' class instance with the following methods:"
        ':$$: 'Text "  * contramap :: (a -> b) -> LogAction m b -> LogAction m a"
        ':$$: 'Text "  * (>$) :: b -> LogAction m b -> LogAction m a"
#endif
        )

{- | ⚠️__CAUTION__⚠️ This instance is for custom error display only.

'LogAction' is not supposed to have 'Functor' instance by design.

In case it is used by mistake, the user  will see the following:

#if MIN_VERSION_base(4,12,0)

>>> fmap show logStringStdout
...
... 'LogAction' cannot have a 'Functor' instance by design.
      However, you've attempted to use this instance.
...
      Probably you meant 'Contravariant' class instance with the following methods:
        * contramap :: (a -> b) -> LogAction m b -> LogAction m a
        * (>$) :: b -> LogAction m b -> LogAction m a
...


#else

>>> fmap show logStringStdout
...
... 'LogAction' cannot have a 'Functor' instance by design.
      However, you've attempted to use this instance.
...

#endif

@since 0.2.1.0
-}
instance UnrepresentableClass => Functor (LogAction m) where
    fmap :: (a -> b) -> LogAction m a -> LogAction m b
    fmap _ _ = error "Unreachable Functor instance of LogAction"

    (<$) :: a -> LogAction m b -> LogAction m a
    _ <$  _ = error "Unreachable Functor instance of LogAction"


{- | Operator version of 'unLogAction'. Note that because of the types, something like:

@
action <& msg1 <& msg2
@

doesn't make sense. Instead you want:

@
action <& msg1 \>\> action <& msg2
@

In addition, because '<&' has higher precedence than the other operators in this
module, the following:

@
f >$< action <& msg
@

is equivalent to:

@
(f >$< action) <& msg
@
-}
infix 5 <&
(<&) :: LogAction m msg -> msg -> m ()
(<&) = coerce
{-# INLINE (<&) #-}

{- | A flipped version of '<&'.

It shares the same precedence as '<&', so make sure to surround lower precedence
operators in parentheses:

@
msg &> (f >$< action)
@
-}
infix 5 &>
(&>) :: msg -> LogAction m msg -> m ()
(&>) = flip (<&)
{-# INLINE (&>) #-}

{- | Joins some 'Foldable' of 'LogAction's into single 'LogAction' using
'Semigroup' instance for 'LogAction'. This is basically specialized version of
'Data.Foldable.fold' function.
-}
foldActions :: (Foldable t, Applicative m) => t (LogAction m a) -> LogAction m a
foldActions actions = LogAction $ \a -> for_ actions $ \(LogAction action) -> action a
{-# INLINE foldActions #-}
{-# SPECIALIZE foldActions :: Applicative m => [LogAction m a]          -> LogAction m a #-}
{-# SPECIALIZE foldActions :: Applicative m => NonEmpty (LogAction m a) -> LogAction m a #-}

----------------------------------------------------------------------------
-- Contravariant combinators
----------------------------------------------------------------------------

{- $contravariant

Combinators that implement interface in the spirit of the following typeclass:

@
__class__ Contravariant f __where__
    contramap :: (a -> b) -> f b -> f a
@
-}

{- | Takes predicate and performs given logging action only if predicate returns
'True' on input logging message.
-}
cfilter :: Applicative m => (msg -> Bool) -> LogAction m msg -> LogAction m msg
cfilter predicate (LogAction action) = LogAction $ \a -> when (predicate a) (action a)
{-# INLINE cfilter #-}

{- | Performs the given logging action only if satisfies the monadic
predicate. Let's say you want to only to see logs that happened on
weekends.

@
isWeekendM :: MessageWithTimestamp -> IO Bool
@

And use it with 'cfilterM' like this

@
logMessageAction :: 'LogAction' m MessageWithTimestamp

logWeekendAction :: 'LogAction' m MessageWithTimestamp
logWeekendAction = cfilterM isWeekendM logMessageAction
@

@since 0.2.1.0
-}
cfilterM :: Monad m => (msg -> m Bool) -> LogAction m msg -> LogAction m msg
cfilterM predicateM (LogAction action) =
    LogAction $ \a -> predicateM a >>= \b -> when b (action a)
{-# INLINE cfilterM #-}

{- | This combinator is @contramap@ from contravariant functor. It is useful
when you have something like

@
__data__ LogRecord = LR
    { lrName    :: LoggerName
    , lrMessage :: Text
    }
@

and you need to provide 'LogAction' which consumes @LogRecord@

@
logRecordAction :: 'LogAction' m LogRecord
@

when you only have action that consumes 'Text'

@
logTextAction :: 'LogAction' m Text
@

With 'cmap' you can do the following:

@
logRecordAction :: 'LogAction' m LogRecord
logRecordAction = 'cmap' lrMesssage logTextAction
@

This action will print only @lrMessage@ from @LogRecord@. But if you have
formatting function like this:

@
formatLogRecord :: LogRecord -> Text
@

you can apply it instead of @lrMessage@ to log formatted @LogRecord@ as 'Text'.
-}
cmap :: (a -> b) -> LogAction m b -> LogAction m a
cmap f (LogAction action) = LogAction (action . f)
{-# INLINE cmap #-}

{- | Operator version of 'cmap'.

>>> 1 &> (show >$< logStringStdout)
1
-}
infixr 3 >$<
(>$<) :: (a -> b) -> LogAction m b -> LogAction m a
(>$<) = cmap
{-# INLINE (>$<) #-}

-- | 'cmap' for convertions that may fail
cmapMaybe :: Applicative m => (a -> Maybe b) -> LogAction m b -> LogAction m a
cmapMaybe f (LogAction action) = LogAction (maybe (pure ()) action . f)
{-# INLINE cmapMaybe #-}

{- | Similar to `cmapMaybe` but for convertions that may fail inside a
monadic context.

@since 0.2.1.0
-}
cmapMaybeM :: Monad m => (a -> m (Maybe b)) -> LogAction m b -> LogAction m a
cmapMaybeM f (LogAction action) = LogAction (maybe (pure ()) action <=< f)
{-# INLINE cmapMaybeM #-}

{- | This combinator is @>$@ from contravariant functor. Replaces all locations
in the output with the same value. The default definition is
@contramap . const@, so this is a more efficient version.

>>> "Hello?" &> ("OUT OF SERVICE" >$ logStringStdout)
OUT OF SERVICE
>>> ("OUT OF SERVICE" >$ logStringStdout) <& 42
OUT OF SERVICE
-}
infixl 4 >$
(>$) :: b -> LogAction m b -> LogAction m a
(>$) b (LogAction action) = LogAction (\_ -> action b)

{- | 'cmapM' combinator is similar to 'cmap' but allows to call monadic
functions (functions that require extra context) to extend consumed value.
Consider the following example.

You have this logging record:

@
__data__ LogRecord = LR
    { lrTime    :: UTCTime
    , lrMessage :: Text
    }
@

and you also have logging consumer inside 'IO' for such record:

@
logRecordAction :: 'LogAction' IO LogRecord
@

But you need to return consumer only for 'Text' messages:

@
logTextAction :: 'LogAction' IO Text
@

If you have function that can extend 'Text' to @LogRecord@ like the function
below:

@
withTime :: 'Text' -> 'IO' LogRecord
withTime msg = __do__
    time <- getCurrentTime
    pure (LR time msg)
@

you can achieve desired behavior with 'cmapM' in the following way:

@
logTextAction :: 'LogAction' IO Text
logTextAction = 'cmapM' withTime myAction
@
-}
cmapM :: Monad m => (a -> m b) -> LogAction m b -> LogAction m a
cmapM f (LogAction action) = LogAction (f >=> action)
{-# INLINE cmapM #-}

----------------------------------------------------------------------------
-- Divisible combinators
----------------------------------------------------------------------------

{- $divisible

Combinators that implement interface in the spirit of the following typeclass:

@
__class__ Contravariant f => Divisible f __where__
    conquer :: f a
    divide  :: (a -> (b, c)) -> f b -> f c -> f a
@
-}

{- | @divide@ combinator from @Divisible@ type class.

>>> logInt = LogAction print
>>> "ABC" &> divide (\s -> (s, length s)) logStringStdout logInt
ABC
3
-}
divide :: (Applicative m) => (a -> (b, c)) -> LogAction m b -> LogAction m c -> LogAction m a
divide f (LogAction actionB) (LogAction actionC) = LogAction $ \(f -> (b, c)) ->
    actionB b *> actionC c
{-# INLINE divide #-}

{- | Monadic version of 'divide'.

@since 0.2.1.0
-}
divideM :: (Monad m) => (a -> m (b, c)) -> LogAction m b -> LogAction m c -> LogAction m a
divideM f (LogAction actionB) (LogAction actionC) =
    LogAction $ \(f -> mbc) -> mbc >>= (\(b, c) -> actionB b *> actionC c)
{-# INLINE divideM #-}

{- | @conquer@ combinator from @Divisible@ type class.

Concretely, this is a 'LogAction' that does nothing:

>>> conquer <& "hello?"
>>> "hello?" &> conquer
-}
conquer :: Applicative m => LogAction m a
conquer = mempty
{-# INLINE conquer #-}

{- | Operator version of @'divide' 'id'@.

>>> logInt = LogAction print
>>> (logStringStdout >*< logInt) <& ("foo", 1)
foo
1
>>> (logInt >*< logStringStdout) <& (1, "foo")
1
foo
-}
infixr 4 >*<
(>*<) :: (Applicative m) => LogAction m a -> LogAction m b -> LogAction m (a, b)
(LogAction actionA) >*< (LogAction actionB) = LogAction $ \(a, b) ->
    actionA a *> actionB b
{-# INLINE (>*<) #-}

{-| Perform a constant log action after another.

>>> logHello = LogAction (const (putStrLn "Hello!"))
>>> "Greetings!" &> (logStringStdout >* logHello)
Greetings!
Hello!
-}
infixr 4 >*
(>*) :: Applicative m => LogAction m a -> LogAction m () -> LogAction m a
(LogAction actionA) >* (LogAction actionB) = LogAction $ \a ->
    actionA a *> actionB ()
{-# INLINE (>*) #-}

-- | A flipped version of '>*'
infixr 4 *<
(*<) :: Applicative m => LogAction m () -> LogAction m a -> LogAction m a
(LogAction actionA) *< (LogAction actionB) = LogAction $ \a ->
    actionA () *> actionB a
{-# INLINE (*<) #-}

----------------------------------------------------------------------------
-- Decidable combinators
----------------------------------------------------------------------------

{- $decidable

Combinators that implement interface in the spirit of the following typeclass:

@
__class__ Divisible f => Decidable f __where__
    lose   :: (a -> Void) -> f a
    choose :: (a -> Either b c) -> f b -> f c -> f a
@
-}

-- | @lose@ combinator from @Decidable@ type class.
lose :: (a -> Void) -> LogAction m a
lose f = LogAction (absurd . f)
{-# INLINE lose #-}

{- | @choose@ combinator from @Decidable@ type class.

>>> logInt = LogAction print
>>> f = choose (\a -> if a < 0 then Left "Negative" else Right a)
>>> f logStringStdout logInt <& 1
1
>>> f logStringStdout logInt <& (-1)
Negative
-}
choose :: (a -> Either b c) -> LogAction m b -> LogAction m c -> LogAction m a
choose f (LogAction actionB) (LogAction actionC) = LogAction (either actionB actionC . f)
{-# INLINE choose #-}

{- | Monadic version of 'choose'.

@since 0.2.1.0
-}
chooseM :: Monad m => (a -> m (Either b c)) -> LogAction m b -> LogAction m c -> LogAction m a
chooseM f (LogAction actionB) (LogAction actionC) = LogAction (either actionB actionC <=< f)
{-# INLINE chooseM #-}

{- | Operator version of @'choose' 'id'@.

>>> dontPrintInt = LogAction (const (putStrLn "Not printing Int"))
>>> Left 1 &> (dontPrintInt >|< logStringStdout)
Not printing Int
>>> (dontPrintInt >|< logStringStdout) <& Right ":)"
:)
-}
infixr 3 >|<
(>|<) :: LogAction m a -> LogAction m b -> LogAction m (Either a b)
(LogAction actionA) >|< (LogAction actionB) = LogAction (either actionA actionB)
{-# INLINE (>|<) #-}

----------------------------------------------------------------------------
-- Comonadic combinators
----------------------------------------------------------------------------

{- $comonad

Combinators that implement interface in the spirit of the following typeclass:

@
__class__ Functor w => Comonad w __where__
    extract   :: w a -> a
    duplicate :: w a -> w (w a)
    extend    :: (w a -> b) -> w a -> w b
@
-}

{- | If @msg@ is 'Monoid' then 'extract' performs given log action by passing
'mempty' to it.

>>> logPrint :: LogAction IO [Int]; logPrint = LogAction print
>>> extract logPrint
[]
-}
extract :: Monoid msg => LogAction m msg -> m ()
extract action = unLogAction action mempty
{-# INLINE extract #-}

-- TODO: write better motivation for comonads
{- | This is a /comonadic extend/. It allows you to chain different transformations on messages.

>>> f (LogAction l) = l ".f1" *> l ".f2"
>>> g (LogAction l) = l ".g"
>>> logStringStdout <& "foo"
foo
>>> extend f logStringStdout <& "foo"
foo.f1
foo.f2
>>> (extend g $ extend f logStringStdout) <& "foo"
foo.g.f1
foo.g.f2
>>> (logStringStdout =>> f =>> g) <& "foo"
foo.g.f1
foo.g.f2
-}
extend :: Semigroup msg => (LogAction m msg -> m ()) -> LogAction m msg -> LogAction m msg
extend f (LogAction action) = LogAction $ \m -> f $ LogAction $ \m' -> action (m <> m')
{-# INLINE extend #-}

-- | 'extend' with the arguments swapped. Dual to '>>=' for a 'Monad'.
infixl 1 =>>
(=>>) :: Semigroup msg => LogAction m msg -> (LogAction m msg -> m ()) -> LogAction m msg
(=>>) = flip extend
{-# INLINE (=>>) #-}

-- | 'extend' in operator form.
infixr 1 <<=
(<<=) :: Semigroup msg => (LogAction m msg -> m ()) -> LogAction m msg -> LogAction m msg
(<<=) = extend
{-# INLINE (<<=) #-}

{- | Converts any 'LogAction' that can log single message to the 'LogAction'
that can log two messages. The new 'LogAction' behaves in the following way:

1. Joins two messages of type @msg@ using '<>' operator from 'Semigroup'.
2. Passes resulted message to the given 'LogAction'.

>>> :{
let logger :: LogAction IO [Int]
    logger = logPrint
in duplicate logger <& ([3, 4], [42, 10])
:}
[3,4,42,10]

__Implementation note:__

True and fair translation of the @duplicate@ function from the 'Control.Comonad.Comonad'
interface should result in the 'LogAction' of the following form:

@
msg -> msg -> m ()
@

In order to capture this behavior, 'duplicate' should have the following type:

@
duplicate :: Semigroup msg => LogAction m msg -> LogAction (Compose ((->) msg) m) msg
@

However, it's quite awkward to work with such type. It's a known fact that the
following two types are isomorphic (see functions 'curry' and 'uncurry'):

@
a -> b -> c
(a, b) -> c
@

So using this fact we can come up with the simpler interface.
-}
duplicate :: forall msg m . Semigroup msg => LogAction m msg -> LogAction m (msg, msg)
duplicate (LogAction l) = LogAction $ \(msg1, msg2) -> l (msg1 <> msg2)
{-# INLINE duplicate #-}


{- | Like 'duplicate' but why stop on a pair of two messages if you can log any
'Foldable' of messages?

>>> :{
let logger :: LogAction IO [Int]
    logger = logPrint
in multiplicate logger <& replicate 5 [1..3]
:}
[1,2,3,1,2,3,1,2,3,1,2,3,1,2,3]
-}
multiplicate
    :: forall f msg m .
       (Foldable f, Monoid msg)
    => LogAction m msg
    -> LogAction m (f msg)
multiplicate (LogAction l) = LogAction $ \msgs -> l (fold msgs)
{-# INLINE multiplicate #-}
{-# SPECIALIZE multiplicate :: Monoid msg => LogAction m msg -> LogAction m [msg] #-}
{-# SPECIALIZE multiplicate :: Monoid msg => LogAction m msg -> LogAction m (NonEmpty msg) #-}

{- | Like 'multiplicate' but instead of logging a batch of messages it logs each
of them separately.

>>> :{
let logger :: LogAction IO Int
    logger = logPrint
in separate logger <& [1..5]
:}
1
2
3
4
5

@since 0.2.1.0
-}
separate
    :: forall f msg m .
       (Traversable f, Applicative m)
    => LogAction m msg
    -> LogAction m (f msg)
separate (LogAction action) = LogAction (traverse_ action)
{-# INLINE separate #-}
{-# SPECIALIZE separate :: Applicative m => LogAction m msg -> LogAction m [msg] #-}
{-# SPECIALIZE separate :: Applicative m => LogAction m msg -> LogAction m (NonEmpty msg) #-}
{-# SPECIALIZE separate :: LogAction IO msg -> LogAction IO [msg] #-}
{-# SPECIALIZE separate :: LogAction IO msg -> LogAction IO (NonEmpty msg) #-}

{- | Allows changing the internal monadic action.

Let's say we have a pure logger action using 'PureLogger'
and we want to log all messages into 'IO' instead.

If we provide the following function:

@
performPureLogsInIO :: PureLogger a -> IO a
@

then we can convert a logger action that uses a pure monad
to a one that performs the logging in the 'IO' monad using:

@
hoistLogAction performPureLogsInIO :: LogAction (PureLogger a) a -> LogAction IO a
@

@since 0.2.1.0
-}
hoistLogAction
    :: (forall x. m x -> n x)
    -> LogAction m a
    -> LogAction n a
hoistLogAction f (LogAction l) = LogAction (f . l)
{-# INLINE hoistLogAction #-}
