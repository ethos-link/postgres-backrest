module.exports = {
  rules: {
    'type-empty': [2, 'never'],
    'type-case': [2, 'always', 'lower-case'],
    'subject-empty': [2, 'never'],
    'body-leading-blank': [2, 'always'],
    'type-enum': [2, 'always', ['feat', 'fix', 'chore', 'refactor', 'docs', 'test', 'perf', 'ci', 'build']],
    'header-max-length': [2, 'always', 72],
    'body-empty': [2, 'never'],
  },
};
