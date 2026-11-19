/// Application metadata constants injected at build time or defaulted to the
/// latest release tag.
const String kAppVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: '1.0.5',
);

const String kAppDisplayName = 'CallbookMaker';
const String kDeveloperGithubId = 'lingzhong-dev';
const String kDeveloperGithubUrl = 'https://github.com/lingzhong-dev';
const String kDeveloperGithubAvatarUrl =
    'https://avatars.githubusercontent.com/u/160128853?v=4';
const String kAppLicenseName = 'GNU GPL v3.0';
