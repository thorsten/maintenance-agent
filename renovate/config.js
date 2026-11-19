// Global Renovate config for all platforms.
// Platform, endpoint and token come from the pipeline:
//   RENOVATE_PLATFORM, RENOVATE_ENDPOINT, RENOVATE_TOKEN,
//   optional RENOVATE_AUTODISCOVER_FILTER (e.g. "my-group/**")
// A repo may override this with its own renovate.json, but does not have to.
module.exports = {
  autodiscover: true,
  onboarding: false,
  requireConfig: 'optional',

  extends: ['config:recommended'],
  labels: ['dependencies', 'renovate'],
  branchPrefix: 'renovate/',

  // Let fresh releases sit for a few days (protection against compromised packages).
  minimumReleaseAge: '3 days',
  prConcurrentLimit: 5,
  prHourlyLimit: 0,

  packageRules: [
    {
      description: 'Merge small updates without review when CI is green',
      matchUpdateTypes: ['patch', 'pin', 'digest'],
      automerge: true,
    },
    {
      description: 'Merge dev dependencies up to minor without review',
      matchDepTypes: ['devDependencies', 'require-dev'],
      matchUpdateTypes: ['minor', 'patch'],
      automerge: true,
    },
  ],

  lockFileMaintenance: {
    enabled: true,
    schedule: ['before 5am on monday'],
  },
};
