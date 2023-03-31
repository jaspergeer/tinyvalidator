module TVC where

data Binop = Add | Sub | Mul | Mod | Div -- arithmetic
           | LAnd | LOr -- boolean
           | BAnd | BOr | Shl | Shr -- binary
           | Eq | Leq | Geq | Lt | Gt -- comparison

data Unop = Neg | LNot | BNot | Deref

data Expr = BinExpr Expr Binop Expr
          | UnopExpr Unop Expr
          | Var Name
          | FunCall Name [Expr]
          | Ref Name
          | Int Int
          | Str String
          | Char Char
          | Float Float
          | Bool Bool

type Name = String

data Stmt = Expr Expr
          | IfElse Expr [Stmt] [Stmt]
          | DeclareAssign Name Expr
          | Declare Name
          | Upd Expr Expr -- *e = e;
          | While Expr [Stmt]
          | For Stmt Expr Stmt [Stmt]
          | Return Expr

data Function = Function [Name] [Stmt]