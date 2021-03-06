module CommentRemoval (
    HighLevelToken,
    isCode, isShortCmt, isLongCmt,
    hltToString,
    isOnlyIndentationLine,
    rmCmtsWrapper,
    lowLevelTokenizeWrapper,
    highLevelTokenizeWrapper,
    tokenizeCodeWrapper,
    compressCodeWrapper,
    weakCompress,
    strongCompress,
) where

import Control.Exception
import Data.Char (isSpace)
import Data.Maybe
import Data.List
import System.IO

import Languages

-- A source file can be seen as a list of text lines. Each one
-- being made of different items :
-- source code, comments, comment delimiters, string constant, etc.
data LowLevelToken = CmtOrCodeOrString Token
                   | CmtBegin          Token
                   | CmtEnd            Token
                   | LineCmtMark       Token
                   | StringBeginOrEnd  Token
                   | EscapedChar       Token
                   deriving Show

type CodeStr     = String
type ShortCmtStr = String
type LongCmtStr  = String

data HighLevelToken = Code             CodeStr
                    | ShortCmt         ShortCmtStr
                    | LongCmt          LongCmtStr
                    | StringInCode     CodeStr
                    | StringInShortCmt ShortCmtStr
                    | StringInLongCmt  LongCmtStr
                    deriving Show

isCode, isShortCmt, isLongCmt :: HighLevelToken -> Bool
isCode (Code _)         = True
isCode (StringInCode _) = True
isCode _                = False

isShortCmt (ShortCmt _)         = True
isShortCmt (StringInShortCmt _) = True
isShortCmt _                    = False

isLongCmt (LongCmt _)         = True
isLongCmt (StringInLongCmt _) = True
isLongCmt _                   = False

type VarOrFunOrConstStr = String
type KeywordStr         = String
type SpecKeywordStr     = String
type SpacingChar        = String

data CodeToken = VarOrFunOrConst VarOrFunOrConstStr
               | Keyword         KeywordStr
               | SpecialKeyword  SpecKeywordStr
               | Spacing         SpacingChar
               | ShortComment    ShortCmtStr
               | LongComment     LongCmtStr
               deriving Show

data ParserState = ReadingCode
                 | ReadingShortCmt
                 | ReadingLongCmt
                 | ReadingStringInCode
                 | ReadingStringInShortCmt
                 | ReadingStringInLongCmt
                 | ReadingEscCharInStringInCode
                 | ReadingEscCharInStringInShortCmt
                 | ReadingEscCharInStringInLongCmt
                 deriving Show

lltToString :: LowLevelToken -> String
lltToString (CmtOrCodeOrString s) = s
lltToString (CmtBegin          s) = s
lltToString (CmtEnd            s) = s
lltToString (LineCmtMark       s) = s
lltToString (StringBeginOrEnd  s) = s
lltToString (EscapedChar       s) = s

hltToString :: HighLevelToken -> String
hltToString (Code             s) = s
hltToString (ShortCmt         s) = s
hltToString (LongCmt          s) = s
hltToString (StringInCode     s) = s
hltToString (StringInShortCmt s) = s
hltToString (StringInLongCmt  s) = s

ctToString :: CodeToken -> String
ctToString (VarOrFunOrConst s) = s
ctToString (Keyword s)         = s
ctToString (SpecialKeyword s)  = s
ctToString (Spacing s)         = s
ctToString (ShortComment s)    = s
ctToString (LongComment s)     = s

isOnlyIndentationLine :: [HighLevelToken] -> Bool
isOnlyIndentationLine [] = False
isOnlyIndentationLine (x:[]) = isOnlyIndentation x
    where
      isOnlyIndentation (Code "") = False
      isOnlyIndentation (Code str) = all isSpace str
      isOnlyIndentation _ = False
isOnlyIndentationLine _ = False

promote :: ParserState -> LowLevelToken -> HighLevelToken
promote ReadingCode             (CmtOrCodeOrString x) = Code             x
promote ReadingShortCmt         (CmtOrCodeOrString x) = ShortCmt         x
promote ReadingLongCmt          (CmtOrCodeOrString x) = LongCmt          x
promote ReadingStringInCode     (CmtOrCodeOrString x) = StringInCode     x
promote ReadingStringInShortCmt (CmtOrCodeOrString x) = StringInShortCmt x
promote ReadingStringInLongCmt  (CmtOrCodeOrString x) = StringInLongCmt  x
promote ReadingCode             (StringBeginOrEnd  x) = StringInCode     x
promote ReadingShortCmt         (StringBeginOrEnd  x) = StringInShortCmt x
promote ReadingLongCmt          (StringBeginOrEnd  x) = StringInLongCmt  x
promote ReadingStringInCode     (StringBeginOrEnd  x) = StringInCode     x
promote ReadingStringInShortCmt (StringBeginOrEnd  x) = StringInShortCmt x
promote ReadingStringInLongCmt  (StringBeginOrEnd  x) = StringInLongCmt  x
promote ReadingStringInCode     (EscapedChar       x) = StringInCode     x
promote ReadingStringInShortCmt (EscapedChar       x) = StringInShortCmt x
promote ReadingStringInLongCmt  (EscapedChar       x) = StringInLongCmt  x
promote ReadingCode             (EscapedChar       x) = Code             x
promote ReadingShortCmt         (EscapedChar       x) = ShortCmt         x
promote ReadingLongCmt          (EscapedChar       x) = ShortCmt         x
promote ReadingEscCharInStringInCode               x  = StringInCode
                                                          (lltToString x)
promote ReadingEscCharInStringInShortCmt           x  = StringInShortCmt
                                                          (lltToString x)
promote ReadingEscCharInStringInLongCmt            x  = StringInLongCmt
                                                          (lltToString x)
promote ReadingStringInCode     (LineCmtMark       x) = StringInCode     x
promote ReadingStringInCode     (CmtBegin          x) = StringInCode     x
promote ReadingStringInCode     (CmtEnd            x) = StringInCode     x
promote _                       (CmtBegin          x) = LongCmt          x
promote _                       (CmtEnd            x) = LongCmt          x
promote _                       (LineCmtMark       x) = ShortCmt         x

startWithList :: [String] -> String -> Maybe String
-- FBR: use a map/fold here instead of explicit recursion ?
startWithList [] _ = Nothing
startWithList (prfx:others) str
    | isPrefixOf prfx str = Just prfx
    | otherwise           = startWithList others str

-- the remaining string is modified by a token or by a letter consumption
firstMatchedTok :: String
                -> [Token] -> [Token] -> [Token] -> [Token] -> [Token]
                -> Maybe (LowLevelToken, String)
firstMatchedTok [] _ _ _ _ _ = Nothing
firstMatchedTok str@(c:cs) cmtStarters cmtStopers shortCmtStarters
                stringDelims escChars =
    case startWithList escChars str of
      Just matched ->
          Just (EscapedChar matched
               ,consumeTokenUnsafe matched str)
      Nothing ->
          case startWithList stringDelims str of
            Just matched ->
                Just (StringBeginOrEnd matched
                     ,consumeTokenUnsafe matched str)
            Nothing ->
                case startWithList cmtStarters str of
                  Just matched ->
                      Just (CmtBegin matched
                           ,consumeTokenUnsafe matched str)
                  Nothing ->
                      case startWithList cmtStopers str of
                        Just matched ->
                            Just (CmtEnd matched
                                 ,consumeTokenUnsafe matched str)
                        Nothing ->
                            case startWithList shortCmtStarters str of
                              Just matched ->
                                  Just (LineCmtMark matched
                                       ,consumeTokenUnsafe matched str)
                              Nothing -> Just (CmtOrCodeOrString (c:[])
                                              ,cs)

-- !!! tok _MUST_ be a prefix of str !!!
consumeTokenUnsafe :: Token -> String -> String
consumeTokenUnsafe tok tokPrefixedStr = drop (length tok) tokPrefixedStr

-- line to list of tokens
tokenizeSrcLine :: Bool
                -> [Token] -> [Token] -> [Token] -> [Token] -> [Token]
                -> [LowLevelToken] -> String -> [LowLevelToken]
-- empty line in source file
tokenizeSrcLine _ _ _ _ _ _ _ "" = (CmtOrCodeOrString ""):[]
-- non empty line
tokenizeSrcLine escaping
                cmtStarters cmtStopers shortCmtStarters stringDelims escChars
                acc srcLine =
    case firstMatchedTok srcLine cmtStarters cmtStopers shortCmtStarters
                         stringDelims escChars of
      Nothing -> reverse acc
      Just (tok, []) -> reverse (factorize escaping tok acc)
      Just (tok, remaining@(_:_)) ->
          case tok of
            EscapedChar _ ->
                tokenizeSrcLine (xor True escaping)
                                cmtStarters cmtStopers shortCmtStarters
                                stringDelims escChars
                                (factorize escaping tok acc) remaining
            _ ->
                tokenizeSrcLine False
                                cmtStarters cmtStopers shortCmtStarters
                                stringDelims escChars
                                (factorize escaping tok acc) remaining
    where
      factorize :: Bool -> LowLevelToken -> [LowLevelToken] -> [LowLevelToken]
      factorize _ elt [] = elt:[]
      factorize escaping' elt lst@(x:xs)
          | escaping' =
              case x of
                (EscapedChar z) ->
                    (EscapedChar (z ++ (lltToString elt))):xs
                _ -> error ("x is not an EscapedChar while we are escaping: "
                            ++ (lltToString elt))
          | otherwise =
              case (elt, x) of
                (CmtOrCodeOrString y, CmtOrCodeOrString z) ->
                    (CmtOrCodeOrString (z ++ y)):xs
                (CmtBegin y, CmtBegin z) ->
                    (CmtBegin (z ++ y)):xs
                (CmtEnd y, CmtEnd z) ->
                    (CmtEnd (z ++ y)):xs
                (LineCmtMark y, LineCmtMark z) ->
                    (LineCmtMark (z ++ y)):xs
                -- consecutive StringBeginOrEnd low level tokens must not be
                -- factorized together to manage correctly the empty string ""
                _ -> elt:lst

xor :: Bool -> Bool -> Bool
xor True True = False
xor _ _ = True

-- file name to list of lines read
getLines :: String -> IO [String]
getLines fileName =
    do mfh <- try (openFile fileName ReadMode)
       case mfh of
         Left err -> do print err
                        return []
         Right h ->
             do getLines' h []
    where
      getLines' :: Handle -> [String] -> IO [String]
      getLines' h acc =
          do mline <- try (hGetLine h)
             case mline of
               Left _ -> return (reverse acc)
               Right line -> getLines' h (line:acc)

-- file name to list of low level tokens
tokenizeFile :: String -> LanguageTags
             -> IO [[LowLevelToken]]
tokenizeFile fileName
             (cmtStarters,cmtStopers,shortCmtStarters,stringDelims,escChars) =
    do readLines <- getLines fileName
       return (map (tokenizeSrcLine False
                                    cmtStarters cmtStopers shortCmtStarters
                                    stringDelims escChars [])
                   readLines)

-- low to high level tokens
highLevelTokens :: [[LowLevelToken]] -> ParserState -> Int
                -> [HighLevelToken] -> Int -> [[HighLevelToken]]
                -> [[HighLevelToken]]
highLevelTokens [] _ _ _ _ acc = reverse acc
highLevelTokens (line:others) parserState depth lineAcc n acc =
    case line of
      -- finished current line
      [] -> case parserState of
              ReadingShortCmt ->
                  -- state only valid until end of current line
                  highLevelTokens others ReadingCode
                                  depth [] nextLine ((reverse lineAcc):acc)
              _ ->
                  highLevelTokens others parserState
                                  depth [] nextLine ((reverse lineAcc):acc)
      -- continuing current line
      tok:toks ->
          case parserState of
            ReadingCode ->
                case tok of
                  CmtOrCodeOrString _ ->
                      highLevelTokens
                         (toks:others) parserState
                         depth (factorize parserState tok lineAcc) n acc
                  LineCmtMark _ ->
                      highLevelTokens
                         (toks:others) ReadingShortCmt
                         depth (factorize ReadingShortCmt tok lineAcc) n acc
                  CmtBegin _ ->
                      highLevelTokens
                         (toks:others) ReadingLongCmt
                         (depth+1) (factorize parserState tok lineAcc) n acc
                  StringBeginOrEnd _ ->
                      highLevelTokens
                         (toks:others) ReadingStringInCode
                         depth (factorize parserState tok lineAcc) n acc
                  CmtEnd mark ->
                      error (linePrfx ++
                             "got EndCmtMArk while ReadingCode: " ++ mark)
                  _ ->
                      highLevelTokens
                         (toks:others) ReadingCode
                         depth (factorize parserState tok lineAcc) n acc
            ReadingShortCmt ->
                case tok of
                  StringBeginOrEnd _ ->
                      highLevelTokens
                         (toks:others) ReadingStringInShortCmt
                         depth (factorize parserState tok lineAcc) n acc
                  _ ->
                      highLevelTokens
                         (toks:others) parserState
                         depth (factorize parserState tok lineAcc) n acc
            ReadingLongCmt ->
                case tok of
                  CmtEnd _ ->
                      let newDepth = depth - 1 in
                      if newDepth == 0 then
                          highLevelTokens
                             (toks:others) ReadingCode
                             newDepth (factorize parserState tok lineAcc) n acc
                      else
                          highLevelTokens
                            (toks:others) parserState
                            newDepth (factorize parserState tok lineAcc) n acc
                  CmtBegin _ ->
                      let newDepth = depth + 1 in
                      highLevelTokens
                         (toks:others) parserState
                         newDepth (factorize parserState tok lineAcc) n acc
                  CmtOrCodeOrString _ ->
                      highLevelTokens
                         (toks:others) parserState
                         depth (factorize parserState tok lineAcc) n acc
                  StringBeginOrEnd _ ->
                      highLevelTokens
                         (toks:others) ReadingStringInLongCmt
                         depth (factorize parserState tok lineAcc) n acc
                  _ ->
                      highLevelTokens
                         (toks:others) ReadingLongCmt
                         depth (factorize parserState tok lineAcc) n acc
            ReadingStringInLongCmt ->
                case tok of
                  StringBeginOrEnd _ ->
                      highLevelTokens
                         (toks:others) ReadingLongCmt
                         depth (factorize parserState tok lineAcc) n acc
                  EscapedChar _ ->
                      highLevelTokens
                         (toks:others) ReadingEscCharInStringInLongCmt
                         depth (factorize parserState tok lineAcc) n acc
                  _ ->
                      highLevelTokens
                         (toks:others) parserState
                         depth (factorize parserState tok lineAcc) n acc
            ReadingStringInShortCmt ->
                case tok of
                  StringBeginOrEnd _ ->
                      highLevelTokens
                         (toks:others) ReadingShortCmt
                         depth (factorize parserState tok lineAcc) n acc
                  EscapedChar _ ->
                      highLevelTokens
                         (toks:others) ReadingEscCharInStringInShortCmt
                         depth (factorize parserState tok lineAcc) n acc
                  _ ->
                      highLevelTokens
                         (toks:others) parserState
                         depth (factorize parserState tok lineAcc) n acc
            ReadingStringInCode ->
                case tok of
                  StringBeginOrEnd _ ->
                      highLevelTokens
                         (toks:others) ReadingCode
                         depth (factorize parserState tok lineAcc) n acc
                  EscapedChar _ ->
                      highLevelTokens
                         (toks:others) ReadingEscCharInStringInCode
                         depth (factorize parserState tok lineAcc) n acc
                  _ ->
                      highLevelTokens
                         (toks:others) parserState
                         depth (factorize parserState tok lineAcc) n acc
            ReadingEscCharInStringInCode ->
                case tok of
                  StringBeginOrEnd _ ->
                      highLevelTokens
                         (toks:others) ReadingCode
                         depth (factorize parserState tok lineAcc) n acc
                  _ ->
                      highLevelTokens
                         (toks:others) ReadingStringInCode
                         depth (factorize parserState tok lineAcc) n acc
            ReadingEscCharInStringInShortCmt ->
                case tok of
                  StringBeginOrEnd _ ->
                      highLevelTokens
                         (toks:others) ReadingShortCmt
                         depth (factorize parserState tok lineAcc) n acc
                  _ ->
                      highLevelTokens
                         (toks:others) ReadingStringInShortCmt
                         depth (factorize parserState tok lineAcc) n acc
            ReadingEscCharInStringInLongCmt ->
                case tok of
                  StringBeginOrEnd _ ->
                      highLevelTokens
                         (toks:others) ReadingLongCmt
                         depth (factorize parserState tok lineAcc) n acc
                  _ ->
                      highLevelTokens
                         (toks:others) ReadingStringInLongCmt
                         depth (factorize parserState tok lineAcc) n acc
    where
      factorize :: ParserState -> LowLevelToken -> [HighLevelToken]
                -> [HighLevelToken]
      factorize state elt [] = (promote state elt):[]
      factorize state elt lst@(x:xs) =
        let elt' = promote state elt in
        case (x, elt') of
          (Code y, Code z) -> (Code (y ++ z)):xs
          (ShortCmt y, ShortCmt z) -> (ShortCmt (y ++ z)):xs
          (LongCmt y, LongCmt z) -> (LongCmt (y ++ z)):xs
          (StringInCode y, StringInCode z) -> (StringInCode (y ++ z)):xs
          (StringInShortCmt y, StringInShortCmt z) ->
              (StringInShortCmt (y ++ z)):xs
          (StringInLongCmt y, StringInLongCmt z) ->
              (StringInLongCmt (y ++ z)):xs
          _ -> elt':lst
      !nextLine = n + 1
      linePrfx = "line " ++ (show n) ++ ": "

-- HighLevelTokens to CodeTokens, non Code high level tokens disappear
tokenizeCodeLowLevel :: [KeywordStr] -> [KeywordStr] -> [[CodeToken]]
                     -> [HighLevelToken] -> [CodeToken]
tokenizeCodeLowLevel _ _ acc [] = (concat . reverse) acc
tokenizeCodeLowLevel lowKwds highKwds acc (tok:toks) =
    case tok of
      Code             s -> processCode s
      StringInCode     s -> processStringInCode s
      ShortCmt         s -> processShortCmt s
      StringInShortCmt s -> processShortCmt s
      LongCmt          s -> processLongCmt s
      StringInLongCmt  s -> processLongCmt s
    where
      processCode s = tokenizeCodeLowLevel lowKwds highKwds
                                           ((parseCode s []):acc)
                                           toks
      processStringInCode s = tokenizeCodeLowLevel lowKwds highKwds
                                                   ([VarOrFunOrConst s]:acc)
                                                   toks
      processShortCmt s = tokenizeCodeLowLevel lowKwds highKwds
                                               ([ShortComment s]:acc)
                                               toks
      processLongCmt s = tokenizeCodeLowLevel lowKwds highKwds
                                              ([LongComment s]:acc)
                                              toks
      parseCode :: CodeStr -> [CodeToken] -> [CodeToken]
      parseCode [] acc' = reverse acc'
      parseCode code acc' =
          case startWithList lowKwds code of
            Just kwd -> -- do we have a keyword?
                let afterKwd = consumeTokenUnsafe kwd code in
                parseCode afterKwd -- yes
                          (factorize (SpecialKeyword kwd) acc')
            Nothing -> -- do we have some spacing?
                case takeWhile isSpace code of
                  [] -> -- no, default fallback
                      let name = takeWhile (not . isSpace) code
                          name' = untilNextKeyword name lowKwds []
                          name'' = if elem name' highKwds
                                   then Keyword name'
                                   else VarOrFunOrConst name' in
                      parseCode (consumeTokenUnsafe name' code)
                                (factorize name'' acc')
                  spacing -> -- yes we have some spacing
                      parseCode (consumeTokenUnsafe spacing code)
                                (factorize (Spacing spacing) acc')

      untilNextKeyword :: CodeStr -> [KeywordStr] -> CodeStr -> CodeStr
      untilNextKeyword [] _ acc' = reverse acc'
      untilNextKeyword code@(c:cs) kwds acc' =
          case startWithList kwds code of
            Just _ -> untilNextKeyword [] kwds acc'
            Nothing -> untilNextKeyword cs kwds (c:acc')

      factorize :: CodeToken -> [CodeToken] -> [CodeToken]
      factorize tok' [] = tok':[]
      factorize tok' acc'@(a:as) =
          case (tok', a) of
            (VarOrFunOrConst x, VarOrFunOrConst y) ->
                (VarOrFunOrConst (y ++ x)):as
            (Spacing x, Spacing y) ->
                (Spacing (y ++ x)):as
            _ -> tok':acc'

rmCmtsWrapper :: String -> ParseInfo -> IO [[HighLevelToken]]
rmCmtsWrapper fileName (haskellTags,_,_) =
    do lowLevelToks <- tokenizeFile fileName haskellTags
       let highLevelToks = highLevelTokens lowLevelToks ReadingCode 0 [] 1 []
           codeOnly = removeComments highLevelToks
       return codeOnly
    where
      removeComments :: [[HighLevelToken]] -> [[HighLevelToken]]
      removeComments srcLine = map (filter isCode) srcLine

lowLevelTokenizeWrapper :: String -> ParseInfo -> IO [[LowLevelToken]]
lowLevelTokenizeWrapper fileName (haskellTags,_,_) =
    do lowLevelToks <- tokenizeFile fileName haskellTags
       return lowLevelToks

highLevelTokenizeWrapper :: String -> ParseInfo -> IO [[HighLevelToken]]
highLevelTokenizeWrapper fileName (haskellTags,_,_) =
    do lowLevelToks <- tokenizeFile fileName haskellTags
       let highLevelToks = highLevelTokens lowLevelToks ReadingCode 0 [] 1 []
       return highLevelToks

tokenizeCodeWrapper :: String -> ParseInfo -> IO [[CodeToken]]
tokenizeCodeWrapper fileName
                    (haskellTags,haskellSpecialKwds,haskellStandardKwds) =
    do checkKwds haskellSpecialKwds haskellStandardKwds
       lowLevelToks <- tokenizeFile fileName haskellTags
       let highLevelToks = highLevelTokens lowLevelToks ReadingCode 0 [] 1 []
           codeToks = map (tokenizeCodeLowLevel haskellSpecialKwds
                                                haskellStandardKwds [])
                          highLevelToks
       return codeToks

checkKwds :: (Eq a, Show a, Monad m) => [a] -> [a] -> m ()
checkKwds l1 l2 =
    let collisions = intersect l1 l2 in
    if collisions /= []
    then error ("collision in low and high level keywords: " ++
               (show collisions))
    else return ()

compressCodeWrapper :: String -> ([CodeToken] -> [CodeToken] -> [CodeToken])
                    -> ParseInfo
                    -> IO [String]
compressCodeWrapper fileName compressor
                    (haskellTags,haskellSpecialKwds,haskellStandardKwds) =
    do checkKwds haskellSpecialKwds haskellStandardKwds
       lowLevelToks <- tokenizeFile fileName haskellTags
       let highLevelToks = highLevelTokens lowLevelToks ReadingCode 0 [] 1 []
           codeToks = map ((compress True []) .
                           (tokenizeCodeLowLevel haskellSpecialKwds
                                                 haskellStandardKwds []))
                          highLevelToks
           codeToks' = map (concat . (map ctToString)) codeToks
       return codeToks'
    where
      -- consecutive spaces become only one, preserves left margin indentation
      compress :: Bool -> [CodeToken] -> [CodeToken] -> [CodeToken]
      compress _ acc [] = reverse acc
      -- skipping left margin indentation
      compress skip@(True) acc lst@(c:cs) =
          case c of
            Spacing _ -> compress skip (c:acc) cs
            _ -> compress False acc lst
      -- no more skipping
      compress False acc lst =
          compress False ((compressor lst []) ++ acc) []

-- remove consecutive spaces
weakCompress :: [CodeToken] -> [CodeToken] -> [CodeToken]
weakCompress [] acc = acc
weakCompress (x:xs) acc =
    case x of
      Spacing _ -> case xs of
                     [] -> weakCompress [] acc
                     x':_ -> case x' of
                               Spacing _ ->
                                   weakCompress xs acc
                               _ -> weakCompress xs ((Spacing " "):acc)
      _ -> weakCompress xs (x:acc)

-- remove consecutive spaces and spaces surrounding special keywords
-- !!! the resulting code doesn't compile, so this changes semantics !!!
-- !!! but may be useful in the future                               !!!
strongCompress :: [CodeToken] -> [CodeToken] -> [CodeToken]
strongCompress [] acc = acc
strongCompress (x:xs) acc =
    case x of
      Spacing _ -> case xs of
                     [] -> strongCompress [] acc
                     x':_ -> case x' of
                               Spacing _ ->
                                   strongCompress xs acc
                               SpecialKeyword _ ->
                                   strongCompress xs acc
                               _ -> strongCompress xs ((Spacing " "):acc)
      SpecialKeyword _ -> case xs of
                            [] -> strongCompress [] (x:acc)
                            x':xs' -> case x' of
                                        Spacing _ ->
                                            strongCompress (x:xs') acc
                                        _ -> strongCompress xs (x:acc)
      _ -> strongCompress xs (x:acc)
