// Tests for the maintainer scripts in module_scripts/. Run with `CI=1 npm test internal`.
module.exports = {
  rootDir: __dirname,
  roots: ['<rootDir>/module_scripts'],
  testMatch: ['<rootDir>/module_scripts/__tests__/**/*.test.js'],
  testEnvironment: 'node',
  transform: {},
};
