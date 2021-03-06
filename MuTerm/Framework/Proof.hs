{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE MultiParamTypeClasses, FunctionalDependencies #-}
{-# LANGUAGE FlexibleContexts, FlexibleInstances, TypeSynonymInstances #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE KindSignatures #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  MuTerm.Framework.Proof
-- Copyright   :  (c) muterm development team
-- License     :  see LICENSE
--
-- Maintainer  :  rgutierrez@dsic.upv.es
-- Stability   :  unstable
-- Portability :  non-portable
--
-- This module contains the proof functor.
--
-----------------------------------------------------------------------------

module MuTerm.Framework.Proof (

-- * Exported data

ProofF(..), Proof

, Info(..), InfoConstraints (..), withInfoOf, PrettyInfo
, SomeInfo (..), someInfo
, IsMZero(..)

-- * Exported functions

, success, singleP, andP, dontKnow, refuted, mand, mprod
, isSuccess, runProof

-- * Evaluation strategies
, parAnds
, sliceProof
) where

import Control.Applicative
import Control.DeepSeq
import Control.Parallel.Strategies
import Control.Monad as M (MonadPlus(..), msum, guard, liftM, join, (>>=))
import Control.Monad.Free (MonadFree(..), Free (..), foldFree)
import Control.Applicative((<$>),Alternative(..))
import Data.Foldable (Foldable(..), toList)
import Data.Traversable as T (Traversable(..), foldMapDefault)
import Data.Maybe (fromMaybe, isNothing, isJust, catMaybes, listToMaybe)
import System.IO.Unsafe (unsafePerformIO)
import Text.PrettyPrint.HughesPJClass

import MuTerm.Framework.Problem


import Prelude as P

-----------------------------------------------------------------------------
-- Proof Tree
-----------------------------------------------------------------------------

-- | Proof Tree constructors
data ProofF info (m :: * -> *) (k :: *) =
    And     {procInfo, problem :: !(SomeInfo info), subProblems::[k]}
  | Or      {procInfo, problem :: !(SomeInfo info), alternatives::m k}
  | Single  {procInfo, problem :: !(SomeInfo info), subProblem::k}
  | Success {procInfo, problem :: !(SomeInfo info)}
  | Refuted {procInfo, problem :: !(SomeInfo info)}
  | DontKnow{procInfo, problem :: !(SomeInfo info)}
  | Search !(m k)
  | MAnd  k k
  | MDone

-- | 'Proof' is a Free Monad. 'm' is the MonadPlus used for search
type Proof info m a = Free (ProofF info m) a

instance NFData a => NFData (ProofF info m a) where
  rnf (And _ _ pp) = rnf pp `seq` ()
  rnf Or{} = ()
  rnf (Single _ _ p) = rnf p `seq` ()
  rnf Success{} = ()
  rnf Refuted{} = ()
  rnf DontKnow{} = ()
  rnf Search{} = ()
  rnf (MAnd p1 p2) = rnf p1 `seq` rnf p2 `seq` ()
  rnf MDone = ()

-- ------------------------------
-- Parameterized super classes
-- ------------------------------

-- Instance witnesses
class Info info p where
  data InfoConstraints info p
  constraints :: InfoConstraints info p

withInfoOf :: Info info a => a -> (InfoConstraints info a -> b) -> b
withInfoOf _ f = f constraints


-- | Pretty printing info witness
data PrettyInfo
instance Pretty p => Info PrettyInfo p where
  data InfoConstraints PrettyInfo p = Pretty p => PrettyInfo
  constraints = PrettyInfo

-- | Tuples of information witnesses
instance (Info i a, Info j a) => Info (i,j) a where
  data InfoConstraints (i,j) a = (:^:) (InfoConstraints i a) (InfoConstraints j a)
  constraints = constraints :^: constraints

-- ------------------------
-- Existential Wrappers
-- ------------------------

-- | 'SomeInfo' hides the type of the proccesor info
data SomeInfo info where
    SomeInfo :: Info info p => p -> SomeInfo info

instance Pretty (SomeInfo PrettyInfo) where
    pPrint (SomeInfo p) = withInfoOf p $ \PrettyInfo -> pPrint p

-- Tuple instances
instance Pretty (SomeInfo (PrettyInfo, a)) where
    pPrint (SomeInfo (p::p)) = withInfoOf p $ \(PrettyInfo :^: (_::InfoConstraints a p)) -> pPrint p

instance Pretty (SomeInfo (a,PrettyInfo)) where
    pPrint (SomeInfo (p::p)) = withInfoOf p $ \((x::InfoConstraints a p) :^: PrettyInfo) -> pPrint p

-----------------------------------------------------------------------------
-- Instances
-----------------------------------------------------------------------------

instance Monad m => Functor (ProofF info m) where
  fmap f (And pi p kk)   = And pi p (fmap f kk)
  fmap f (Single pi p k) = Single pi p (f k)
  fmap _ (Success pi p)  = Success pi p
  fmap _ (Refuted pi p)  = Refuted pi p
  fmap _ (DontKnow pi p) = DontKnow pi p
  fmap f (Search mk)     = Search (liftM f mk)
  fmap f (MAnd k1 k2)    = MAnd (f k1) (f k2)
  fmap f MDone           = MDone

instance (Monad m, Traversable m) => Foldable (ProofF info m) where foldMap = T.foldMapDefault

instance (Monad m, Traversable m) => Traversable (ProofF info m) where
  traverse f (And pi p kk)   = And pi p <$> traverse f kk
  traverse f (Single pi p k) = Single pi p <$> f k
  traverse _ (Success pi p)  = pure $ Success pi p
  traverse _ (Refuted pi p)  = pure $ Refuted pi p
  traverse _ (DontKnow pi p) = pure $ DontKnow pi p
  traverse f (Search mk)     = Search <$> traverse f mk
  traverse f (MAnd k1 k2)    = MAnd <$> f k1 <*> f k2
  traverse f MDone           = pure MDone


-- MonadPlus

instance MonadPlus m => Alternative (Free (ProofF info m)) where
   empty        = Impure (Search mzero)
   (!p1) <|> p2   = Impure (Search (mplus (return p1) (return p2)))

instance MonadPlus m => MonadPlus (Free (ProofF info m))

-- Show
-----------------------------------------------------------------------------
-- Smart Constructors
-----------------------------------------------------------------------------

-- | Return a success node
success :: (Monad m, Info info p, Info info problem) => p -> problem -> Proof info m b
success pi p0 = Impure (Success (someInfo pi) (someProblem p0))

-- | Return a refuted node
refuted :: (Monad m, Info info p, Info info problem) => p -> problem -> Proof info m b
refuted pi p0 = Impure (Refuted (someInfo pi) (someProblem p0))

-- | Returns a don't know node
dontKnow :: (Monad m, Info info p, Info info problem) => p -> problem -> Proof info m b
dontKnow pi p0 = Impure (DontKnow (someInfo pi) (someProblem p0))

-- | Return a new single node
singleP :: (Monad m, Info info p, Info info problem) => p -> problem -> b -> Proof info m b
singleP pi p0 p = Impure (Single (someInfo pi) (someProblem p0) (return p))

-- | Return a list of nodes
andP :: (Monad m, Info info p, Info info problem) => p -> problem -> [b] -> Proof info m b
andP pi p0 [] = success pi p0
andP pi p0 pp = Impure (And (someInfo pi) (someProblem p0) (map return pp))

mand :: Monad m => Proof info m a -> Proof info m a -> Proof info m a
mand a b = Impure (MAnd a b)

mprod :: Monad m => [Proof info m a] -> Proof info m a
mprod = P.foldr mand (Impure MDone) where
  mand a (Impure MDone) = a
  mand a b = Impure (MAnd a b)

-- ---------
-- Functions
-- ---------

-- | Pack the proof information
someInfo :: Info info p => p -> SomeInfo info
someInfo    = SomeInfo

-- | Pack the problem
someProblem :: Info info p => p -> SomeInfo info
someProblem = SomeInfo

-- | Obtain the solution, collecting the proof path in the way
evalSolF' :: (MonadPlus mp) => ProofF info mp (mp(Proof info t ())) -> mp (Proof info t ())
evalSolF' Refuted{..}    = return (Impure Refuted{..})
evalSolF' DontKnow{}     = mzero
evalSolF' MDone          = return (Impure MDone)
evalSolF' Success{..}    = return (Impure Success{..})
evalSolF' (Search mk)    = join mk
evalSolF' (And pi pb []) = return (Impure $ Success pi pb)
evalSolF' (And pi pb ll) = (Impure . And pi pb) `liftM` P.sequence ll
evalSolF' (Or  pi pb ll) = (Impure . Single pi pb) `liftM` join ll
evalSolF' (MAnd  p1 p2)  = p1 >>= \s1 -> p2 >>= \s2 ->
                           return (Impure $ MAnd s1 s2)
evalSolF' (Single pi pb p) = (Impure . Single pi pb) `liftM` p


class MonadPlus mp => IsMZero mp where isMZero :: mp a -> Bool
instance IsMZero []    where isMZero = null
instance IsMZero Maybe where isMZero = isNothing

-- | Evaluate if proof is success
isSuccess :: IsMZero mp => Proof info mp a -> Bool
isSuccess = not . isMZero . foldFree (const mzero) evalSolF'

-- | Apply the evaluation returning the relevant proof subtree
runProof :: MonadPlus mp => Proof info mp a -> mp (Proof info m ())
runProof = foldFree (const mzero) evalSolF'

-- Evaluation Strategies
-- Evaluate and branches in parallel
parAnds :: Strategy (Proof info m a)
parAnds (Pure p) = return (Pure p)
parAnds (Impure i) = liftM Impure (f i) where
   f (And    pi p pp)= And    pi p <$> parList parAnds pp
   f (Single pi p k) = Single pi p <$> parAnds k
   f (MAnd p1 p2)    = MAnd <$> rpar (p1 `using` parAnds) <*> rpar (p2 `using` parAnds)
   f it = return it

-- | Evaluates the needed branches of a proof removing the unsuccesful ones.
--   Useful for things like displaying a failed proof.
sliceProof :: IsMZero mp => Proof info mp a -> Proof info mp a
sliceProof = foldFree return (Impure . f) where
    f (Or  p pi pp) = Or  p pi (pp >>= \p -> guard (not $ isSuccess p) >> return p)
    f (And p pi pp) = (And p pi $ takeWhileAndOneMore isSuccess pp)
    f (MAnd     p1 p2) = if not(isSuccess p1) then Search (return p1) else (MAnd p1 p2)
    f x = x
    takeWhileAndOneMore _ []     = []
    takeWhileAndOneMore f (x:xs) = if f x then x : takeWhileAndOneMore f xs else [x]
