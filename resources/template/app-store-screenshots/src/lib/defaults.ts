import { DEFAULT_LOCALE } from "./locale";
import { DEFAULT_THEME_ID, PROJECT_SCHEMA_VERSION } from "./constants";
import type { Device, ProjectState, Slide } from "./types";

let _id = 0;
export const nid = () => `s_${Date.now().toString(36)}_${(_id++).toString(36)}`;

const en = (s: string) => ({ [DEFAULT_LOCALE]: s });

function makeStarterSlides(): Slide[] {
  return [
    {
      id: nid(),
      layout: "hero",
      label: en("MEET YOUR APP"),
      headline: en("Sell one\nidea per slide."),
      screenshot: {},
    },
    {
      id: nid(),
      layout: "device-bottom",
      label: en("FEATURE 01"),
      headline: en("Your headline\nlives here."),
      screenshot: {},
    },
    {
      id: nid(),
      layout: "two-devices",
      label: en("FEATURE 02"),
      headline: en("Show two\nscreens at once."),
      screenshot: {},
      screenshotSecondary: {},
    },
    {
      id: nid(),
      layout: "device-top",
      label: en("FEATURE 03"),
      headline: en("Flip the contrast\nfor visual rhythm."),
      screenshot: {},
      inverted: true,
    },
    {
      id: nid(),
      layout: "no-device",
      label: en("MORE"),
      headline: en("And so\nmuch more."),
      screenshot: {},
    },
  ];
}

function ipadStarter(): Slide[] {
  return [
    {
      id: nid(),
      layout: "hero",
      label: en("MEET YOUR APP"),
      headline: en("Made for\nthe big screen."),
      screenshot: {},
    },
    {
      id: nid(),
      layout: "device-bottom",
      label: en("FEATURE 01"),
      headline: en("Built for\nfocus."),
      screenshot: {},
    },
    {
      id: nid(),
      layout: "device-top",
      label: en("FEATURE 02"),
      headline: en("Always within reach."),
      screenshot: {},
      inverted: true,
    },
  ];
}

function tabletStarter(kind: "7" | "10"): Slide[] {
  return [
    {
      id: nid(),
      layout: "hero",
      label: en("MEET YOUR APP"),
      headline: en(kind === "7" ? "Pocket-sized\npower." : "Made for\nthe big screen."),
      screenshot: {},
    },
    {
      id: nid(),
      layout: "split-landscape",
      label: en("FEATURE 01"),
      headline: en("Wide canvas,\nbigger ideas."),
      screenshot: {},
    },
  ];
}

function fgStarter(): Slide[] {
  return [
    {
      id: nid(),
      layout: "feature-graphic",
      label: {},
      headline: en("Your tagline goes here."),
      screenshot: {},
    },
  ];
}

function watchStarter(): Slide[] {
  return [
    {
      id: "wtc_01",
      layout: "hero",
      label: en("ON YOUR WRIST"),
      headline: en("Tap to capture\nany thought."),
      screenshot: en("/screenshots/apple/watch-45mm/{locale}/01.png"),
    },
    {
      id: "wtc_02",
      layout: "device-bottom",
      label: en("HISTORY"),
      headline: en("All your\nrecordings."),
      screenshot: en("/screenshots/apple/watch-45mm/{locale}/02.png"),
    },
    {
      id: "wtc_03",
      layout: "no-device",
      label: en("ALWAYS READY"),
      headline: en("Quick capture\nfrom your wrist."),
      screenshot: {},
    },
  ];
}

// The wide canvas carries half as many slides before a deck starts to feel
// padded, so the Duo starter ships two instead of the phone's six.
function duoStarter(): Slide[] {
  return [
    {
      id: nid(),
      layout: "hero",
      label: en("UNFOLDED"),
      headline: en("A wide canvas\nof its own."),
      screenshot: {},
    },
    {
      id: nid(),
      layout: "device-bottom",
      label: en("FEATURE 01"),
      headline: en("More room,\nsame app."),
      screenshot: {},
    },
  ];
}

export const DEFAULT_PROJECT: ProjectState = {
  schemaVersion: PROJECT_SCHEMA_VERSION,
  appName: "My App",
  themeId: DEFAULT_THEME_ID,
  connectedCanvas: true,
  locales: [DEFAULT_LOCALE],
  locale: DEFAULT_LOCALE,
  device: "iphone",
  orientation: "portrait",
  appIcon: "",
  slidesByDevice: {
    iphone: makeStarterSlides(),
    "iphone-duo": duoStarter(),
    android: makeStarterSlides(),
    ipad: ipadStarter(),
    "watch-45mm": watchStarter(),
    "android-7": tabletStarter("7"),
    "android-10": tabletStarter("10"),
    "feature-graphic": fgStarter(),
  },
};

export function newSlide(layout: Slide["layout"] = "device-bottom"): Slide {
  return {
    id: nid(),
    layout,
    label: en("NEW"),
    headline: en("Edit this\nheadline."),
    screenshot: {},
  };
}

export function detectPlatform(device: Device): "ios" | "android" {
  return device === "iphone" ||
    device === "iphone-duo" ||
    device === "ipad" ||
    device === "watch-45mm"
    ? "ios"
    : "android";
}
