{-# LANGUAGE NoMonomorphismRestriction#-}
{-|

'AccountName's are strings like @assets:cash:petty@, with multiple
components separated by ':'.  From a set of these we derive the account
hierarchy.

-}

module Hledger.Data.AccountName
where
import Data.List
import Data.Map (Map)
import Data.Tree
import Test.HUnit
import Text.Printf
import qualified Data.Map as M

import Hledger.Data.Types
import Hledger.Utils



-- change to use a different separator for nested accounts
acctsepchar = ':'

accountNameComponents :: AccountName -> [String]
accountNameComponents = splitAtElement acctsepchar

accountNameFromComponents :: [String] -> AccountName
accountNameFromComponents = concat . intersperse [acctsepchar]

accountLeafName :: AccountName -> String
accountLeafName = last . accountNameComponents

accountNameLevel :: AccountName -> Int
accountNameLevel "" = 0
accountNameLevel a = length (filter (==acctsepchar) a) + 1

accountNameDrop :: Int -> AccountName -> AccountName
accountNameDrop n = accountNameFromComponents . drop n . accountNameComponents

-- | ["a:b:c","d:e"] -> ["a","a:b","a:b:c","d","d:e"]
expandAccountNames :: [AccountName] -> [AccountName]
expandAccountNames as = nub $ concatMap expand as
    where expand = map accountNameFromComponents . tail . inits . accountNameComponents

-- | ["a:b:c","d:e"] -> ["a","d"]
topAccountNames :: [AccountName] -> [AccountName]
topAccountNames as = [a | a <- expandAccountNames as, accountNameLevel a == 1]

parentAccountName :: AccountName -> AccountName
parentAccountName = accountNameFromComponents . init . accountNameComponents

parentAccountNames :: AccountName -> [AccountName]
parentAccountNames a = parentAccountNames' $ parentAccountName a
    where
      parentAccountNames' "" = []
      parentAccountNames' a = a : parentAccountNames' (parentAccountName a)

isAccountNamePrefixOf :: AccountName -> AccountName -> Bool
isAccountNamePrefixOf = isPrefixOf . (++ [acctsepchar])

isSubAccountNameOf :: AccountName -> AccountName -> Bool
s `isSubAccountNameOf` p = 
    (p `isAccountNamePrefixOf` s) && (accountNameLevel s == (accountNameLevel p + 1))

-- | From a list of account names, select those which are direct
-- subaccounts of the given account name.
subAccountNamesFrom :: [AccountName] -> AccountName -> [AccountName]
subAccountNamesFrom accts a = filter (`isSubAccountNameOf` a) accts

-- | Convert a list of account names to a tree.
accountNameTreeFrom :: [AccountName] -> Tree AccountName
accountNameTreeFrom = accountNameTreeFrom1

accountNameTreeFrom1 accts = 
    Node "top" (accounttreesfrom (topAccountNames accts))
        where
          accounttreesfrom :: [AccountName] -> [Tree AccountName]
          accounttreesfrom [] = []
          accounttreesfrom as = [Node a (accounttreesfrom $ subs a) | a <- as]
          subs = subAccountNamesFrom (expandAccountNames accts)

nullaccountnametree = Node "top" []

accountNameTreeFrom2 accts = 
   Node "top" $ unfoldForest (\a -> (a, subs a)) $ topAccountNames accts
        where
          subs = subAccountNamesFrom allaccts
          allaccts = expandAccountNames accts
          -- subs' a = subsmap ! a
          -- subsmap :: Map AccountName [AccountName]
          -- subsmap = Data.Map.fromList [(a, subAccountNamesFrom allaccts a) | a <- allaccts]

accountNameTreeFrom3 accts = 
    Node "top" $ forestfrom allaccts $ topAccountNames accts
        where
          -- drop accts from the list of potential subs as we add them to the tree
          forestfrom :: [AccountName] -> [AccountName] -> Forest AccountName
          forestfrom subaccts accts = 
              [let subaccts' = subaccts \\ accts in Node a $ forestfrom subaccts' (subAccountNamesFrom subaccts' a) | a <- accts]
          allaccts = expandAccountNames accts
          

-- a more efficient tree builder from Cale Gibbard
newtype Tree' a = T (Map a (Tree' a))
  deriving (Show, Eq, Ord)

mergeTrees :: (Ord a) => Tree' a -> Tree' a -> Tree' a
mergeTrees (T m) (T m') = T (M.unionWith mergeTrees m m')

emptyTree = T M.empty

pathtree :: [a] -> Tree' a
pathtree []     = T M.empty
pathtree (x:xs) = T (M.singleton x (pathtree xs))

fromPaths :: (Ord a) => [[a]] -> Tree' a
fromPaths = foldl' mergeTrees emptyTree . map pathtree

-- the above, but trying to build Tree directly

-- mergeTrees' :: (Ord a) => Tree a -> Tree a -> Tree a
-- mergeTrees' (Node m ms) (Node m' ms') = Node undefined (ms `union` ms')

-- emptyTree' = Node "top" []

-- pathtree' :: [a] -> Tree a
-- pathtree' []     = Node undefined []
-- pathtree' (x:xs) = Node x [pathtree' xs]

-- fromPaths' :: (Ord a) => [[a]] -> Tree a
-- fromPaths' = foldl' mergeTrees' emptyTree' . map pathtree'


-- converttree :: [AccountName] -> Tree' AccountName -> [Tree AccountName]
-- converttree parents (T m) = [Node (accountNameFromComponents $ parents ++ [a]) (converttree (parents++[a]) b) | (a,b) <- M.toList m]

-- accountNameTreeFrom4 :: [AccountName] -> Tree AccountName
-- accountNameTreeFrom4 accts = Node "top" (converttree [] $ fromPaths $ map accountNameComponents accts)

converttree :: Tree' AccountName -> [Tree AccountName]
converttree (T m) = [Node a (converttree b) | (a,b) <- M.toList m]

expandTreeNames :: Tree AccountName -> Tree AccountName
expandTreeNames (Node x ts) = Node x (map (treemap (\n -> accountNameFromComponents [x,n]) . expandTreeNames) ts)

accountNameTreeFrom4 :: [AccountName] -> Tree AccountName
accountNameTreeFrom4 = Node "top" . map expandTreeNames . converttree . fromPaths . map accountNameComponents


-- | Elide an account name to fit in the specified width.
-- From the ledger 2.6 news:
-- 
-- @
--   What Ledger now does is that if an account name is too long, it will
--   start abbreviating the first parts of the account name down to two
--   letters in length.  If this results in a string that is still too
--   long, the front will be elided -- not the end.  For example:
--
--     Expenses:Cash           ; OK, not too long
--     Ex:Wednesday:Cash       ; "Expenses" was abbreviated to fit
--     Ex:We:Afternoon:Cash    ; "Expenses" and "Wednesday" abbreviated
--     ; Expenses:Wednesday:Afternoon:Lunch:Snack:Candy:Chocolate:Cash
--     ..:Af:Lu:Sn:Ca:Ch:Cash  ; Abbreviated and elided!
-- @
elideAccountName :: Int -> AccountName -> AccountName
elideAccountName width s = 
    elideLeft width $ accountNameFromComponents $ elideparts width [] $ accountNameComponents s
      where
        elideparts :: Int -> [String] -> [String] -> [String]
        elideparts width done ss
          | length (accountNameFromComponents $ done++ss) <= width = done++ss
          | length ss > 1 = elideparts width (done++[take 2 $ head ss]) (tail ss)
          | otherwise = done++ss

clipAccountName :: Int -> AccountName -> AccountName
clipAccountName n = accountNameFromComponents . take n . accountNameComponents

-- | Convert an account name to a regular expression matching it and its subaccounts.
accountNameToAccountRegex :: String -> String
accountNameToAccountRegex "" = ""
accountNameToAccountRegex a = printf "^%s(:|$)" a

-- | Convert an account name to a regular expression matching it and its subaccounts.
accountNameToAccountOnlyRegex :: String -> String
accountNameToAccountOnlyRegex "" = ""
accountNameToAccountOnlyRegex a = printf "^%s$" a

-- | Convert an exact account-matching regular expression to a plain account name.
accountRegexToAccountName :: String -> String
accountRegexToAccountName = regexReplace "^\\^(.*?)\\(:\\|\\$\\)$" "\\1"

-- | Does this string look like an exact account-matching regular expression ?
isAccountRegex  :: String -> Bool
isAccountRegex s = take 1 s == "^" && (take 5 $ reverse s) == ")$|:("

tests_Hledger_Data_AccountName = TestList
 [
  "accountNameTreeFrom" ~: do
    accountNameTreeFrom ["a"]       `is` Node "top" [Node "a" []]
    accountNameTreeFrom ["a","b"]   `is` Node "top" [Node "a" [], Node "b" []]
    accountNameTreeFrom ["a","a:b"] `is` Node "top" [Node "a" [Node "a:b" []]]
    accountNameTreeFrom ["a:b:c"]   `is` Node "top" [Node "a" [Node "a:b" [Node "a:b:c" []]]]

  ,"expandAccountNames" ~:
    expandAccountNames ["assets:cash","assets:checking","expenses:vacation"] `is`
     ["assets","assets:cash","assets:checking","expenses","expenses:vacation"]

  ,"isAccountNamePrefixOf" ~: do
    "assets" `isAccountNamePrefixOf` "assets" `is` False
    "assets" `isAccountNamePrefixOf` "assets:bank" `is` True
    "assets" `isAccountNamePrefixOf` "assets:bank:checking" `is` True
    "my assets" `isAccountNamePrefixOf` "assets:bank" `is` False

  ,"isSubAccountNameOf" ~: do
    "assets" `isSubAccountNameOf` "assets" `is` False
    "assets:bank" `isSubAccountNameOf` "assets" `is` True
    "assets:bank:checking" `isSubAccountNameOf` "assets" `is` False
    "assets:bank" `isSubAccountNameOf` "my assets" `is` False

 ]

