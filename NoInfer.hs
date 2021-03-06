{-|
As 'effectfully' pointed out, infering types for annotated lambdas is the only place
where we need substitution or closures. If we only check but not infer lambdas, there's
no need for Infer.

https://www.reddit.com/r/dependent_types/comments/4cvbkm/dependent_type_checking_without_substitution/d1mpm39

-}

{-# language BangPatterns, LambdaCase, OverloadedStrings #-}

module NoInfer where

import Prelude hiding (pi)
import Control.Monad
import Data.Either
import qualified Data.HashMap.Strict as HM

import Syntax (RawTerm)
import qualified Syntax as S

data Term
  = Var !Int -- db Level 
  | App Term Term
  | Lam Term 
  | Pi Term Term
  | Ann Term Term
  | Star
  deriving (Eq)

data Val
  = VVar !Int
  | VApp Val Val
  | VLam (Val -> Val)
  | VPi Type (Val -> Val)
  | VStar

type Type  = Val
type Cxt   = ([Val], [Type], Int)
type TM    = Either String

cxt0 :: Cxt
cxt0 = ([], [], 0)

(<:) :: (Val, Type) -> Cxt -> Cxt
(<:) (v, t) (vs, ts, d) = (v:vs, t:ts, d + 1)

(<::) :: Type -> Cxt -> Cxt
(<::) t (vs, ts, d) = (VVar d:vs, t:ts, d + 1)

vapp :: Val -> Val -> Val
vapp (VLam f) x = f x
vapp f        x = VApp f x

eval :: [Val] -> Int -> Term -> Val
eval vs d = \case
  Var i    -> vs !! (d - i - 1)
  App f x  -> eval vs d f `vapp` eval vs d x
  Ann t ty -> eval vs d t
  Lam   t  -> VLam $ \v -> eval (v:vs) (d + 1) t
  Pi  a b  -> VPi  (eval vs d a) $ \v -> eval (v:vs) (d + 1) b
  Star     -> VStar

quote :: Int -> Val -> Term
quote d = \case
  VVar i   -> Var i
  VApp f x -> App (quote d f) (quote d x)
  VLam   t -> Lam (quote (d + 1) (t (VVar d)))
  VPi  a b -> Pi  (quote d a) (quote (d + 1) (b (VVar d)))
  VStar    -> Star

nf :: [Val] -> Int -> Term -> Term
nf vs d t = quote d (eval vs d t)

check :: Cxt -> Term -> Type -> TM ()
check cxt@(vs, ts, d) t want = case (t, want) of
  (Lam t, VPi a b) -> do
    check (a <:: cxt) t (b (VVar d))
  (t, ty) -> do
    let want' = quote d want
    has <- quote d <$> infer cxt t
    unless (has == want') $ Left "type mismatch"

infer :: Cxt -> Term -> TM Type
infer cxt@(vs, ts, d) = \case
  Var i   -> pure (ts !! (d - i - 1))
  Star    -> pure VStar
  Lam t   -> Left "can't infer type for lambda"
  Pi a b -> do
    check cxt a VStar
    check (eval vs d a <:: cxt) b VStar
    pure VStar
  Ann t ty -> do
    check cxt ty VStar
    let ty' = eval vs d ty
    ty' <$ check cxt t ty'
  App f x -> do
    infer cxt f >>= \case
      VPi a b -> do
        check cxt x a
        pure $ b (eval vs d x)
      _ -> Left "can't apply non-function"

-- Test
--------------------------------------------------------------------------------

fromRaw :: RawTerm -> Term
fromRaw = go HM.empty 0 where
  go m !d (S.Var v)     = Var (m HM.! v)
  go m d  (S.ILam v t)  = Lam (go (HM.insert v d m) (d + 1) t)
  go m d  (S.Ann t ty)  = Ann (go m d t) (go m d ty)
  go m d  (S.Pi  v a t) = Pi  (go m d a) (go (HM.insert v d m) (d + 1) t)
  go m d  (S.App f x)   = App (go m d f) (go m d x)
  go m d  S.Star        = Star

pretty :: Int -> Term -> ShowS
pretty prec = go (prec /= 0) where

  unwords' :: [ShowS] -> ShowS
  unwords' = foldr1 (\x acc -> x . (' ':) . acc)

  spine :: Term -> Term -> [Term]
  spine f x = go f [x] where
    go (App f y) args = go f (y : args)
    go t         args = t:args

  go :: Bool -> Term -> ShowS
  go p (Var i)    = (show i++)
  go p (App f x)  = showParen p (unwords' $ map (go True) (spine f x))
  go p (Lam   t)  = showParen p (("λ "++) . go False t)
  go p Star       = ('*':)
  go p (Ann t ty) = showParen p (go True t . (" : "++) . go False ty)
  go p (Pi a b)   = showParen p (go True a . (" -> "++) . go False b)

instance Show Term where
  showsPrec = pretty

infer0 :: RawTerm -> TM Term
infer0 = (quote 0 <$>) .infer cxt0 . fromRaw

eval0 :: RawTerm -> TM Term
eval0 t = quote 0 (eval [] 0 $ fromRaw t) <$ infer0 t

v = S.Var
lam = S.ILam
pi = S.Pi
star = S.Star
ann = flip S.Ann
($$) = S.App
infixl 9 $$

(==>) :: RawTerm -> RawTerm -> RawTerm
a ==> b = pi "" a b
infixr 8 ==>

id' =
  ann (pi "a" star $ "a" ==> "a") $
  lam "a" $ lam "x" $ "x"

const' =
  ann (pi "a" star $ pi "b" star $ "a" ==> "b" ==> "a") $
  lam "a" $ lam "b" $ lam "x" $ lam "y" $ "x"



-- compose =
--   forAll "a" $
--   forAll "b" $
--   forAll "c" $
--   lam "f" ("b" ==> "c") $
--   lam "g" ("a" ==> "b") $
--   lam "x" "a" $
--   "f" $$ ("g" $$ "x")

-- nat = pi "a" star $ ("a" ==> "a") ==> "a" ==> "a"

-- z = forAll "a" $
--     lam "s" ("a" ==> "a") $
--     lam"z" "a"
--     "z"

-- s = lam "n" nat $
--     forAll "a" $
--     lam "s" ("a" ==> "a") $
--     lam "z" "a" $
--     "s" $$ ("n" $$ "a" $$ "s" $$ "z")

-- add =
--   lam "a" nat $
--   lam "b" nat $
--   forAll "r" $
--   lam "s" ("r" ==> "r") $
--   lam "z" "r" $
--   "a" $$ "r" $$ "s" $$ ("b" $$ "r" $$ "s" $$ "z")

-- mul =
--   lam "a" nat $
--   lam "b" nat $
--   forAll "r" $
--   lam "s" ("r" ==> "r") $
--   "a" $$ "r" $$ ("b" $$ "r" $$ "s")

-- two = s $$ (s $$ z)
-- five = s $$ (s $$ (s $$ (s $$ (s $$ z))))
-- ten = add $$ five $$ five
-- hundred = mul $$ ten $$ ten

-- nFunTy =
--   lam "n" nat $
--   "n" $$ star $$ (lam "t" star $ star ==> "t") $$ star

-- nFun =
--   lam "n" nat $
--   lam "f" (nFunTy $$ "n") $
--   star

-- list = forAll "a" $ pi "r" star $ ("a" ==> "r" ==> "r") ==> "r" ==> "r"

-- nil = forAll "a" $ forAll "r" $ lam "c" ("a" ==> "r" ==> "r") $ lam "n" "r" $ "n"

-- cons =
--    forAll "a" $
--    lam "x" "a" $
--    lam "xs" (list $$ "a") $
--    forAll "r" $ lam "c" ("a" ==> "r" ==> "r") $ lam "n" "r" $
--    "c" $$ "x" $$ ("xs" $$ "r" $$ "c" $$ "n")

-- map' =
--   forAll "a" $
--   forAll "b" $
--   lam "f" ("a" ==> "b") $
--   lam "as" (list $$ "a") $
--   "as" $$ (list $$ "b") $$
--     (lam "x" "a" $ lam "xs" (list $$ "b") $ cons $$ "b" $$ ("f" $$ "x") $$ "xs") $$
--     (nil $$ "b")

-- sum' = lam "xs" (list $$ nat) $ "xs" $$ nat $$ add $$ z

-- natList = let c = cons $$ nat; n = nil $$ nat in
--   c $$ z $$ (c $$ five $$ (c $$ ten $$ n))

-- test = all (isRight . infer0)
--   [id', const', compose, nat, z, s, add, mul, two, five, nFunTy, nFun,
--    nFun $$ five, sum' $$ natList, map']

-- tenK = mul $$ hundred $$ hundred
-- million = mul $$ hundred $$ tenK

-- -- reduction-heavy example
-- stress =
--   lam "x" (nFunTy $$ million) $
--   cons $$ (nFunTy $$ million) $$ "x" $$
--   (nil $$ (nFunTy $$ million))


