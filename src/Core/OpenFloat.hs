-----------------------------------------------------------------------------
-- Copyright 2020 Microsoft Corporation, Daan Leijen, Ningning Xie
--
-- This is free software; you can redistribute it and/or modify it under the
-- terms of the Apache License, Version 2.0. A copy of the License can be
-- found in the file "license.txt" at the root of this distribution.
-----------------------------------------------------------------------------

-----------------------------------------------------------------------------
-- Flt all local and anonymous functions to top level. No more letrec :-)
-----------------------------------------------------------------------------

module Core.OpenFloat( openFloat ) where


import qualified Lib.Trace
import Control.Monad
import Control.Applicative
import Data.Maybe( catMaybes )
import Lib.PPrint
import Common.Failure
import Common.NamePrim ( nameEffectOpen )
import Common.Name
import Common.Range
import Common.Unique
import Common.Error
import Common.Syntax

import Kind.Kind
import Type.Type
import Type.Kind
import Type.TypeVar
import Type.Pretty hiding (Env)
import qualified Type.Pretty as Pretty
import Type.Assumption
import Core.Core
import qualified Core.Core as Core
import Core.Pretty

trace s x =
   Lib.Trace.trace s
    x

enable = -- set to True to enable the transformation
  True
  -- False

openFloat :: Pretty.Env -> Gamma -> CorePhase ()
openFloat penv gamma
  = liftCorePhaseUniq $ \uniq defs ->
    let
      (expr, i) = runFlt penv gamma uniq $
        (if enable then fltDefGroups else return) defs
    in (expr, i)


{--------------------------------------------------------------------------
  transform definition groups
--------------------------------------------------------------------------}
fltDefGroups :: DefGroups -> Flt DefGroups
fltDefGroups = foldr fltDefGroup (return [])

fltDefGroup :: DefGroup -> Flt [DefGroup] -> Flt [DefGroup]
fltDefGroup (DefRec defs) next
  = do defs' <-  mapM fltDef defs
       next' <- next
       return $ DefRec defs' : next'

fltDefGroup (DefNonRec def) next
 = do def' <- fltDef def
      next' <-  next
      return $ DefNonRec def' : next'

fltDef :: Def -> Flt Def
fltDef def
  = withCurrentDef def $
    do (expr', _) <- fltExpr (defExpr def) Nothing
       return def{ defExpr = expr' }

-- exor : typrOf(expr) | \eff ~~> (expr', rq)
fltExpr :: Expr -> Maybe Effect -> Flt (Expr, Req)
fltExpr expr maybeEff
  = case expr of
    -- flt open[...](f)(args)  = flt f(args)
    App (App eopen@(TypeApp (Var open _) [effFrom,effTo,tpFrom,tpTo]) [f]) args | getName open == nameEffectOpen
      -> do fltExpr  (App f args) maybeEff

    App f args
      -> do (f', rqf) <- fltExpr f maybeEff
            args_rq' <- mapM (\arg -> fltExpr arg maybeEff) args
            tp <- getFunType f  -- debug
            let (args', rqs) = unzip args_rq'
                Just(_, feff, _) = splitFunType tp
                rqSup = sup $ Eff feff  : rqf : rqs
                frest = smartRestrictExpr rqf rqSup f'
                f'' = smartOpenExpr (Eff feff) rqSup frest
                args'' = map (\(e, rq)-> smartRestrictExpr rq rqSup e) args_rq'
            traceDoc $ \env -> text "app: " <+> niceType env (typeOf f'')
            return (assertTypeInvariant $ App f'' args'', rqSup)
            where
              getFunType :: Expr -> Flt Type
              getFunType expr = case typeOf expr of
                funtp@TFun{} -> return funtp
                tp -> do traceDoc $ \env -> text "App" <+> niceType env tp
                         return tp

    Lam args eff body
      -> do   
            traceDoc $ \env -> text "lambda:" <+> niceType env eff
            (body', rq) <- fltExpr body $ Just eff
            let rqSup = supb (Eff eff) rq
            if matchRq rqSup $ Eff eff then return ()
              else traceDoc $ \env -> text "bad lambda!! before:" <+> niceType env (typeOf expr) <+> text "\n  eff: " <+> niceType env (orderEffect eff) <+> text "\n  req : " <+> niceRq  env rq
            return (
              --  assertion ("lambda bad body rq\n Why this lambda type checked?\n Annotated effect does not range over internal effect of the body." ++ show (typeOf expr)) (matchRq rqSup $ Eff eff) . 
               assertTypeInvariant $ Lam args eff body',
               Bottom)

    Let defgs body
      -> do defgIR_rqs <- mapM (\def -> fltDefGroupAux def maybeEff) defgs
            (body', rq) <- fltExpr body maybeEff
            let (defgIRs, rqs) = unzip defgIR_rqs
                rqSup = sup $ rq:rqs
            defgs' <- mapM (restrictToDG rqSup) defgIRs
            return (assertTypeInvariant $ Let defgs' body', rqSup)
    Case exprs bs
      -> do exprIR_rqs <- mapM (\exp-> fltExpr exp maybeEff)exprs
            bIR_rqs <- mapM (\b -> fltBranchAux b maybeEff) bs
            let rqe = foldl supb Bottom $ map snd exprIR_rqs
                (bIRs, rqbs) = unzip bIR_rqs
                rqSup = sup $ rqe : rqbs
            exprs'' <- mapM (restrictToE rqSup) exprIR_rqs
            bs'' <- mapM (restrictToB rqSup) bIRs
            return (assertTypeInvariant $ Case exprs'' bs'', rqSup)

    -- type application and abstraction
    TypeLam tvars body
      -> do (body', rq) <- fltExpr body maybeEff
            return (assertTypeInvariant $ TypeLam tvars body', Bottom)

    TypeApp body tps
      -> do (body', rq) <- fltExpr body maybeEff
            return (assertTypeInvariant $ TypeApp body' tps, rq)

    -- the rest
    _ -> return (expr, Bottom)
    where
      assertTypeInvariant :: Expr -> Expr
      assertTypeInvariant expr' =
        let tpBefore = typeOf expr
            tpAfter = typeOf expr' in
              assertion "OpenFloat. Type invariant violaiton." (matchType tpBefore tpAfter) expr'
      restrictToD :: Req -> DefIR -> Flt Def
      restrictToD rqSup (DefIR def@Def{defExpr=expr} rq) = return $ def{defExpr= smartRestrictExpr rq rqSup expr}
      restrictToDG :: Req -> DefGroupIR -> Flt DefGroup
      restrictToDG rqSup (DefRecIR defIRs) =
        do defs <- mapM (restrictToD rqSup) defIRs
           return $ DefRec defs
      restrictToDG rqSup (DefNonRecIR defIR) =
        do def <- restrictToD rqSup defIR
           return $ DefNonRec def
      restrictToE :: Req -> (Expr, Req) -> Flt Expr
      restrictToE rqSup (e, rq) = return $ smartRestrictExpr rq rqSup e
      restrictToB :: Req -> BranchIR -> Flt Branch
      restrictToB rqSup (BranchIR pt gIRs) =
        do guards' <- mapM (restrictToG rqSup) gIRs
           return $ Branch pt guards'
      restrictToG :: Req -> GuardIR -> Flt Guard
      restrictToG rqSup (GuardIR t g) =
        do testExpr' <- restrictToE rqSup t
           guardExpr' <- restrictToE rqSup g
           return $ Guard testExpr' guardExpr'

      fltDefAux :: Def -> Maybe Effect -> Flt (DefIR, Req)
      fltDefAux def@Def{defExpr=expr} maybeEff =
        do (expr', rq) <- fltExpr expr maybeEff
           return (DefIR def{defExpr=expr'} rq, rq)

      fltDefGroupAux :: DefGroup -> Maybe Effect -> Flt (DefGroupIR, Req)
      fltDefGroupAux (DefRec defs) maybeEff =
        do defIR_rqs <- mapM (\def -> fltDefAux def maybeEff) defs
           let (defIRs, rqs) = unzip defIR_rqs
           return (DefRecIR defIRs, sup rqs)
      fltDefGroupAux (DefNonRec def) maybeEff =
        do (defIR, rq) <- fltDefAux def maybeEff
           return (DefNonRecIR defIR, rq)

      fltBranchAux :: Branch -> Maybe Effect -> Flt (BranchIR, Req)
      fltBranchAux (Branch pat guards) maybeEff =
        do guard_rqs <- mapM (\guard -> fltGuardAux guard maybeEff ) guards
           let (guards', rqs) = unzip guard_rqs
           return (BranchIR pat guards', sup rqs)

      fltGuardAux :: Guard -> Maybe Effect -> Flt (GuardIR, Req)
      fltGuardAux (Guard guard body) maybeEff =
        do (guard', rqg) <- fltExpr guard maybeEff
           (body', rqb)  <- fltExpr body maybeEff
           return (GuardIR (guard', rqg) (body', rqb), supb rqg rqb)

{--------------------------------------------------------------------------
  Requirement
--------------------------------------------------------------------------}

data Req = Eff Effect | Bottom deriving (Eq, Show)

sup :: [Req] -> Req
sup = foldl supb Bottom

supb :: Req -> Req -> Req
supb Bottom rq = rq
supb rq Bottom = rq
supb (Eff eff1) (Eff eff2) = Eff $ supbEffect eff1 eff2


supbEffect :: Effect -> Effect -> Effect
supbEffect eff1 eff2 =
  let
    (labs1, tl1) = extractOrderedEffect eff1
    (labs2, tl2) = extractOrderedEffect eff2
    tl = assertion
           ("OpenFlaot. sup undefined between:\n" ++ "A. " ++ show tl1 ++ "\nB. " ++ show tl2)
           (isEffectEmpty tl1 || isEffectEmpty tl2 || tl1 `matchEffect` tl2 )
           (if isEffectEmpty tl1 then tl2 else tl1)
    labs = mergeLabs labs1 labs2
  in effectExtends labs tl
  where
    compareLabel :: Tau -> Tau -> Ordering
    compareLabel l1 l2 = let (name1, i1, args1) = labelNameEx l1
                             (name2, i2, args2) = labelNameEx l2
                         in case labelNameCompare name1 name2 of
                              EQ ->
                                (case (args1, args2) of
                                      ([TVar (TypeVar id1 kind1 sort1)], [TVar (TypeVar id2 kind2 sort2)]) -> compare id1 id2
                                      _ -> assertion ("openFloat: unexpected label-args. Label argument should only differ in variable case. \n1. " ++ show args1 ++ "\n2. " ++ show args2) (
                                             all (\(t1, t2)-> matchType t1 t2) $ zip args1 args2
                                              ) EQ
                                    )
                              order -> order

    mergeLabs :: [Tau] -> [Tau] -> [Tau]
    mergeLabs [] labs = labs
    mergeLabs labs [] = labs
    -- It is ok to use `compareLabel`, because
    --   if l1 `compareLabel` l2 then (l1 equal l2 including the argument, since the expr type check) 
    mergeLabs labs1@(l1:ls1) labs2@(l2:ls2) = case l1 `compareLabel` l2 of
      EQ -> l1:mergeLabs ls1 ls2
      LT -> l1:mergeLabs ls1 labs2
      GT -> l2:mergeLabs labs1 ls2

matchEffect :: Effect -> Effect -> Bool
matchEffect eff1 eff2 = matchType (orderEffect eff1) (orderEffect eff2)

matchRq :: Req -> Req -> Bool
matchRq Bottom Bottom = True
matchRq (Eff eff1) (Eff eff2) = matchEffect eff1 eff2
matchRq _ _ = False

leqRq :: Req -> Req -> Bool
leqRq rq1 rq2 = let rqSup = supb rq1 rq2 in matchRq rqSup rq2

niceRq :: Pretty.Env -> Req -> Doc
niceRq env Bottom = text "Bottom"
niceRq env (Eff eff) = text "Eff " <+> niceType env eff

{--------------------------------------------------------------------------
  smart open
--------------------------------------------------------------------------}

-- How should I define restrict?
smartRestrictExpr :: Req -> Req -> Expr  -> Expr
smartRestrictExpr Bottom _ expr = expr
smartRestrictExpr (Eff _) Bottom _ = undefined
smartRestrictExpr (Eff effFrom) (Eff effTo) expr =
  if matchEffect effFrom effTo then expr else
    -- let x = \_.expr in (open(x) ())  ~~> (\x. open(x)() ) \_.expr
    let
      tp = typeOf expr
      fname = newHiddenName "restedthunk"
      ftname = TName fname (TFun [] effFrom tp)
      -- tmptname = TName (newHiddenName "tmp") typeUnit
      in App
           (Lam [ftname] effTo (  -- ([] -> effFrom tp) -> effTo 
              App (openEffectExpr effFrom effTo (TFun [] effFrom tp) (TFun [] effTo tp) (Var ftname InfoNone)) []))
           [Lam [] effFrom expr]  -- :: [] -> effFrom tp

smartOpenExpr :: Req -> Req -> Expr -> Expr
smartOpenExpr Bottom _ e = e
smartOpenExpr (Eff _) Bottom _ = undefined
smartOpenExpr (Eff effFrom) (Eff effTo) expr =
  if matchEffect effFrom effTo then expr else
    let tp@(TFun tpPar feff tpRes)= typeOf expr
        in
          assertion "smart open check" (matchEffect effFrom feff) $
          openEffectExpr effFrom effTo tp (TFun tpPar effTo tpRes) expr

-- smartRestrictDefGroups :: Req -> (DefGroups, Req) -> DefGroups 
-- smartRestrictDefGroup :: Req -> 


{--------------------------------------------------------------------------
  IRs : Return type of auxiliary functions. Each Expr has own rq in order to be restricted.
--------------------------------------------------------------------------}

data BranchIR = BranchIR { branchPatterns :: [Pattern]
                         , branchGuardIRs :: [GuardIR]}
data GuardIR = GuardIR { guardTestIR :: (Expr, Req)
                       , guardExprIR :: (Expr, Req)}
data DefIR = DefIR { def :: Def, req :: Req}
data DefGroupIR = DefRecIR [DefIR] | DefNonRecIR DefIR

{--------------------------------------------------------------------------
  Flt monad
--------------------------------------------------------------------------}
newtype Flt a = Flt (Env -> State -> Result a)

data Env = Env{ currentDef :: [Def],
                prettyEnv :: Pretty.Env,
                gamma :: Gamma
              }

data State = State{ uniq :: Int }

data Result a = Ok a State

runFlt :: Pretty.Env -> Gamma -> Int -> Flt a -> (a,Int)
runFlt penv gamma u (Flt c)
  = case c (Env [] penv gamma) (State u) of
      Ok x st -> (x,uniq st)

instance Functor Flt where
  fmap f (Flt c)  = Flt (\env st -> case c env st of
                                        Ok x st' -> Ok (f x) st')

instance Applicative Flt where
  pure  = return
  (<*>) = ap

instance Monad Flt where
  return x       = Flt (\env st -> Ok x st)
  (Flt c) >>= f = Flt (\env st -> case c env st of
                                      Ok x st' -> case f x of
                                                    Flt d -> d env st' )

instance HasUnique Flt where
  updateUnique f = Flt (\env st -> Ok (uniq st) st{ uniq = (f (uniq st)) })
  setUnique  i   = Flt (\env st -> Ok () st{ uniq = i} )

withEnv :: (Env -> Env) -> Flt a -> Flt a
withEnv f (Flt c)
  = Flt (\env st -> c (f env) st)

--withUnique :: (Int -> (a,Int)) -> Flt a
--withUnique f
-- = Flt (\env st -> let (x,u') = f (uniq st) in Ok x (st{ uniq = u'}))

getEnv :: Flt Env
getEnv
  = Flt (\env st -> Ok env st)

updateSt :: (State -> State) -> Flt State
updateSt f
  = Flt (\env st -> Ok st (f st))

withCurrentDef :: Def -> Flt a -> Flt a
withCurrentDef def action
  = -- trace ("inl def: " ++ show (defName def)) $
    withEnv (\env -> env{currentDef = def:currentDef env}) $
    do -- traceDoc $ (\penv -> text "\ndefinition:" <+> prettyDef penv{Pretty.coreShowDef=True} def)
       action

traceDoc :: (Pretty.Env -> Doc) -> Flt ()
traceDoc f
  = do env <- getEnv
       fltTrace (show (f (prettyEnv env)))

fltTrace :: String -> Flt ()
fltTrace msg
  = do env <- getEnv
       trace ("open float: " ++ show (map defName (currentDef env)) ++ ": " ++ msg) $ return ()