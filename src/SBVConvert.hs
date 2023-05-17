{-# LANGUAGE FlexibleContexts #-}

module SBVConvert where

import qualified AST
import qualified SymbolicExecution as E
import qualified SymbolicExpression as X
import Data.SBV
import Data.SBV.Tuple

import Data.Map (toList)

-- data SBVConvertException = 

-- Array helpers
toArrN :: (SFiniteBits a, SDivisible (SBV a), SIntegral a, SymVal a, HasKind tup) => ([SBV Int32] -> SBV tup) -> X.Expr -> Symbolic (SArray tup a)
toArrN tupleN e = case e of
  X.NewArr {} -> newArray_ Nothing
  X.Upd e1 es e2 -> do
    arr <- toArrN tupleN e1
    is <- tupleN <$> mapM convertExp es
    val <- convertExp e2
    return $ writeArray arr is val
  _ -> error "tried to interpret non-array value as array"

tuple1 :: [SBV a] -> SBV a
tuple1 [a] = a
tuple1 _ = undefined

tuple2 :: (SymVal a) => [SBV a] -> SBV (a, a)
tuple2 [a, b] = tuple (a, b)
tuple2 _ = undefined

toArr1 :: (SFiniteBits b, SIntegral b, SymVal b, SDivisible (SBV b)) => X.Expr -> Symbolic (SArray Int32 b)
toArr1 = toArrN tuple1

toArr2 :: (SFiniteBits b, SIntegral b, SymVal b, SDivisible (SBV b)) => X.Expr -> Symbolic (SArray (Int32, Int32) b)
toArr2 = toArrN tuple2

-- Non-array symbolic expressions become SBV expressions
convertExp :: (SFiniteBits a, SDivisible (SBV a), SIntegral a, SymVal a, Num a, Ord a) => X.Expr -> Symbolic (SBV a)
convertExp e = case e of
  X.Literal i -> free $ show i
  X.FromType t e1 -> case t of   
    X.Int32 -> do
      s <- convertExp e1 :: Symbolic (SBV Int32)
      return $ sFromIntegral s
    X.Int8 -> do
      s <- convertExp e1 :: Symbolic (SBV Int8)
      return $ sFromIntegral s
    _ -> do -- Ptr, U32
      s <- convertExp e1 :: Symbolic (SBV Word32)
      return $ sFromIntegral s
  X.Sel e1 es -> do
    xs <- mapM convertExp es
    case es of
      [_] -> do
        arr <- toArr1 e1
        return $ readArray arr (tuple1 xs)
      [_, _] -> do
        arr <- toArr2 e1
        return $ readArray arr (tuple2 xs)
      _ -> error "higher dimensional arrays not supported"
  X.ArithExpr e1 binop e2 ->
    let
      convertArith op = case op of
        AST.Add -> (+)
        AST.Sub -> (-)
        AST.Mul -> (*)
        AST.Div -> sDiv
        AST.Mod -> sMod
    in
      do
        s1 <- convertExp e1
        s2 <- convertExp e2
        return $ convertArith binop s1 s2
  X.LogExpr e1 binop e2 ->
    let
      convertLog op = case op of
        AST.LAnd -> (.&&)
        AST.LOr -> (.||)
    in do
      s1 <- convertExp e1 :: Symbolic SInt32 -- according to C99
      let b1 = s1 ./= 0
      s2 <- convertExp e2 :: Symbolic SInt32
      let b2 = s2 ./= 0
      return $ oneIf (convertLog binop b1 b2)
  X.BitExpr e1 binop e2 ->
    let
      convertBit op = case op of
        AST.BAnd -> (.&.)
        AST.BOr -> (.|.)
        AST.Shl -> sShiftLeft
        AST.Shr -> sSignedShiftArithRight
    in do
      s1 <- convertExp e1
      s2 <- convertExp e2
      return $ convertBit binop s1 s2
  X.RelExpr e1 binop e2 ->
    let
      convertRel op = case op of
        AST.Eq -> (.==)
        AST.Leq -> (.<=)
        AST.Geq -> (.>=)
        AST.Lt -> (.<)
        AST.Gt -> (.>)
    in do
      s1 <- convertExp e1 :: Symbolic SInt32
      s2 <- convertExp e2 :: Symbolic SInt32
      return $ oneIf (convertRel binop s1 s2)
  X.UnExpr op e1 -> do
    s1 <- convertExp e1
    case op of
      AST.Neg ->
        return $ negate s1
      AST.LNot ->
        return $ oneIf (s1 .== 0)
      AST.BNot ->
        return $ complement s1
  X.PtrTo n -> return $ sym ("ptrto_" ++ n)
  X.Free n -> return $ uninterpret ("free_" ++ n)
  X.FunCall funname args -> do
    xs <- mapM convertExp args :: Symbolic [SInt32]
    case args of
      [_] -> do
        let f = uninterpret funname
        return $ f (tuple1 xs)
      [_, _] -> do
        let f = uninterpret funname
        return $ f (tuple2 xs)
      _ -> error ("functions of " ++ show (length args) ++ " arguments not supported")
  X.NewArr {} -> error "array encountered as value"
  X.Upd {} -> error "array encountered as value"
  _ -> error "TODO"

-- Each heap object becomes an uninterpreted function with a constraint
convertEnv :: E.VarEnv -> Symbolic [()]
convertEnv env =
  let
    convertBinding (n, (e, tau)) =
      case X.dim tau of
        1 -> do
          let f = uninterpret n :: SBV Int32 -> SWord32
          arr <- toArr1 e
          constrain $ \(Forall x) -> f x .== readArray arr x
        2 -> do
          let f = uninterpret n :: SBV (Int32, Int32) -> SWord32
          arr <- toArr2 e
          constrain $ \(Forall x) -> f x .== readArray arr x
        _ -> error "higher dimensional arrays not supported"
  in mapM convertBinding (toList env)

-- Treat path condition as a conjunction
convertPathCond :: [X.Expr] -> Symbolic SBool
convertPathCond [] = return sTrue
convertPathCond (g:gs) = do
  c1 <- (./=) 0 <$> (convertExp g :: Symbolic SWord32)
  c2 <- convertPathCond gs
  return $ c1 .&& c2

