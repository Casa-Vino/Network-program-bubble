/// Selected by the development APK workflow; ordinary builds remain Bubble.
const isBubbleDev = bool.fromEnvironment('BUBBLE_DEV');
const appName = isBubbleDev ? 'Bubble Dev' : 'Bubble';
const updateRelease = isBubbleDev ? 'bubble-dev-latest' : 'mobile-latest';
const appVersionUrl =
    'https://github.com/Casa-Vino/Network-program-bubble/releases/download/$updateRelease/version.json';
