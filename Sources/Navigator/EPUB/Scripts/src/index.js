//
//  Copyright 2025 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

// Base script used by both reflowable and fixed layout resources.

import "./gestures";
import "./keyboard";
import { findFirstVisibleLocator, findFirstVisibleLocatorInRect } from "./dom";
import {
  documentHeight,
  removeProperty,
  resolveVerticalOffset,
  scrollLeft,
  scrollRight,
  scrollToId,
  scrollToPosition,
  scrollToLocator,
  setProperty,
  setCSSProperties,
  setViewportRect,
} from "./utils";
import { getDecorations, registerTemplates } from "./decorator";

// Public API used by the navigator.
global.readium = {
  // utils
  scrollToId: scrollToId,
  scrollToPosition: scrollToPosition,
  scrollToLocator: scrollToLocator,
  scrollLeft: scrollLeft,
  scrollRight: scrollRight,
  setCSSProperties: setCSSProperties,
  setProperty: setProperty,
  removeProperty: removeProperty,
  setViewportRect: setViewportRect,
  documentHeight: documentHeight,
  resolveVerticalOffset: resolveVerticalOffset,

  // decoration
  registerDecorationTemplates: registerTemplates,
  getDecorations: getDecorations,

  // DOM
  findFirstVisibleLocator: findFirstVisibleLocator,
  findFirstVisibleLocatorInRect: findFirstVisibleLocatorInRect,
};
