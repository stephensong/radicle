module Radicle.Internal.Parse where

import           Protolude hiding (SrcLoc, try)

import qualified Data.Map as Map
import qualified Data.Sequence as Seq
import           GHC.Exts (IsString(..))
import           Text.Megaparsec
                 ( ParsecT
                 , between
                 , choice
                 , eof
                 , getSourcePos
                 , manyTill
                 , satisfy
                 , sepBy
                 , try
                 , (<?>)
                 )
import qualified Text.Megaparsec as M
import           Text.Megaparsec.Char (char, space1, string)
import qualified Text.Megaparsec.Char.Lexer as L
import qualified Text.Megaparsec.Error as Par

import           Radicle.Internal.Annotation as Ann
import           Radicle.Internal.Core
import           Radicle.Internal.Identifier

-- * The parser

type Parser a = ParsecT Void Text Identity a
type VParser = Parser Value

spaceConsumer :: Parser ()
spaceConsumer = L.space space1 lineComment blockComment
  where
    lineComment  = L.skipLineComment ";;"
    blockComment = L.skipBlockComment "#|" "|#" -- R6RS

tag :: ValueF Value -> VParser
tag v = do
    pos <- getSourcePos
    pure $ Ann.Annotated (Ann.WithPos (Ann.SrcPos pos) v)

symbol :: Text -> Parser Text
symbol = L.symbol spaceConsumer

lexeme :: Parser a -> Parser a
lexeme = L.lexeme spaceConsumer

inside :: Text -> Text -> Parser a -> Parser a
inside b e = between (symbol b >> spaceConsumer) (spaceConsumer >> symbol e)

parensP :: Parser a -> Parser a
parensP = inside "(" ")"

bracesP :: Parser a -> Parser a
bracesP = inside "{" "}"

sqBracketsP :: Parser a -> Parser a
sqBracketsP = inside "[" "]"

-- Parsing of string literals handles escape sequences just like Haskell does.
stringLiteralP :: VParser
stringLiteralP = lexeme $ tag =<< StringF . toS <$> escapedString
  where
    escapedString = catMaybes <$> (char '"' >> manyTill ch (char '"'))
    ch = (Just <$> L.charLiteral) <|> (Nothing <$ string "\\&")

boolLiteralP :: VParser
boolLiteralP = lexeme $ tag =<< BooleanF <$> (char '#' >>
        (char 't' >> pure True) <|> (char 'f' >> pure False))

numLiteralP :: VParser
numLiteralP = tag =<< NumberF <$> signed pos
  where
    posrat =
      do n <- L.decimal
         _ <- char '/'
         d <- L.decimal
         pure (n % d)

    pos = try posrat <|> fromIntegral <$> (L.decimal :: Parser Integer)

    -- We don't allow spaces between the sign and digits so that we can remain
    -- consistent with the general Scheme of things.
    signed p = M.option identity ((identity <$ char '+') <|> (negate <$ char '-')) <*> p

identP :: Parser Ident
identP = lexeme $ do
    l <- satisfy isValidIdentFirst
    r <- many (satisfy isValidIdentRest)
    pure . Ident $ fromString (l:r)

atomP :: VParser
atomP = tag . AtomF =<< identP

keywordP :: VParser
keywordP = do
  _ <- char ':'
  kw <- many (satisfy isValidIdentRest)
  tag . KeywordF . Ident . fromString $ kw

listP :: VParser
listP = parensP (tag =<< (ListF <$> valueP `sepBy` spaceConsumer))

vecP :: VParser
vecP = sqBracketsP (tag =<< (VecF . Seq.fromList <$> valueP `sepBy` spaceConsumer))

dictP :: VParser
dictP = bracesP (tag =<< (DictF . Map.fromList <$> evenItems))
  where
    evenItems = twoItems `sepBy` spaceConsumer
    twoItems = do
      x <- valueP
      spaceConsumer
      y <- valueP
      pure (x,y)

quoteP :: VParser
quoteP = do
    val <- char '\'' >> valueP
    q <- tag $ AtomF (unsafeToIdent "quote")
    pure $ List [q, val]

valueP :: VParser
valueP = do
  v <- choice
      [ stringLiteralP <?> "string"
      , boolLiteralP <?> "boolean"
      , keywordP <?> "keyword"
      , try numLiteralP <?> "number"
      , atomP <?> "identifier"
      , quoteP <?> "quote"
      , listP <?> "list"
      , vecP <?> "vector"
      , dictP <?> "dict"
      ]
  spaceConsumer
  pure v

-- * Utilities

-- | Parse a Text as a series of values.
--
-- Note that parsing continues even if one value fails to parse.
parseValues
    :: Text    -- ^ Name of source file (for error reporting)
    -> Text    -- ^ Source code to be parsed
    -> Either (Par.ParseErrorBundle Text Void) [Value]
parseValues sourceName srcCode
    = M.parse (spaceConsumer *> many valueP <* eof) (toS sourceName) srcCode

-- | Parse a single value.
--
-- Examples:
--
-- >>> untag <$> parse "test" "#t" :: Either Text UntaggedValue
-- Right (Annotated (Identity (BooleanF True)))
--
-- >>> untag <$> parse "test" "hi" :: Either Text UntaggedValue
-- Right (Annotated (Identity (AtomF (Ident {fromIdent = "hi"}))))
parse :: MonadError Text m
    => Text    -- ^ Name of source file (for error reporting)
    -> Text    -- ^ Source code to be parsed
    -> m Value
parse file src = do
  let res = runIdentity (M.runParserT (spaceConsumer *> valueP <* eof) (toS file) src)
  case res of
    Left err -> throwError . toS $ M.errorBundlePretty err
    Right v  -> pure v

-- | Smart constructor for Ident.
mkIdent :: Text -> Maybe Ident
mkIdent t = case runIdentity (M.runParserT (valueP <* M.eof) "" t) of
    -- We use the 'valueP' parser instead of 'identP' so that we don’t
    -- negative numbers  like @-4@.
    Right (Atom i) -> pure i
    _              -> Nothing
