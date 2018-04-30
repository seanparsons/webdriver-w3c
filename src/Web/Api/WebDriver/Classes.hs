{- |
Module      : Web.Api.WebDriver.Classes
Description : Utility typeclasses
Copyright   : 2018, Automattic, Inc.
License     : GPL-3
Maintainer  : Nathan Bloomfield (nbloomf@gmail.com)
Stability   : experimental
Portability : POSIX
-}

module Web.Api.WebDriver.Classes (
    HasElementRef(..)
  ) where

import Web.Api.WebDriver.Types

class HasElementRef t where
  elementRefOf :: t -> ElementRef

instance HasElementRef ElementRef where
  elementRefOf = id
