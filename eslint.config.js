// @ts-check

import eslint from '@eslint/js';
import tseslint from 'typescript-eslint';
import pluginVue from 'eslint-plugin-vue';
import eslintConfigPrettier from 'eslint-config-prettier';

export default tseslint.config(
  {
    ignores: [
      'node_modules/**',
      'deps/**',
      'priv/static/**',
      'dist/**',
      'build/**',
    ],
  },
  eslint.configs.recommended,
  ...tseslint.configs.recommended,
  ...pluginVue.configs['flat/recommended'],
  {
    files: ['**/*.{js,ts,vue}'],
    languageOptions: {
      globals: {
        // Browser globals
        window: 'readonly',
        document: 'readonly',
        console: 'readonly',
        setTimeout: 'readonly',
        clearTimeout: 'readonly',
        setInterval: 'readonly',
        clearInterval: 'readonly',
        localStorage: 'readonly',
        navigator: 'readonly',
        HTMLElement: 'readonly',
        MouseEvent: 'readonly',
        TouchEvent: 'readonly',
        DragEvent: 'readonly',
        KeyboardEvent: 'readonly',
        Node: 'readonly',
        // Node.js globals for config files
        process: 'readonly',
        __dirname: 'readonly',
        require: 'readonly',
        module: 'readonly',
      },
    },
  },
  {
    files: ['**/*.vue'],
    languageOptions: {
      parserOptions: {
        parser: tseslint.parser,
        extraFileExtensions: ['.vue'],
        sourceType: 'module',
        ecmaVersion: 2022,
      },
    },
  },
  {
    rules: {
      // Vue specific customizations
      'vue/multi-word-component-names': 'off', // Allow single word component names
      'vue/require-default-prop': 'off',
      'vue/first-attribute-linebreak': 'off', // Allow multiple attributes on same line
      'vue/attributes-order': 'off', // Disable strict attribute ordering
      // TypeScript specific customizations
      '@typescript-eslint/no-unused-vars': ['error', { argsIgnorePattern: '^_' }],
      '@typescript-eslint/no-explicit-any': 'warn',
      '@typescript-eslint/no-require-imports': 'off', // Allow require() in vendor files
      // JavaScript specific customizations
      'no-undef': 'off', // Turn off since we define globals above
      'no-case-declarations': 'off', // Allow declarations in case blocks
    },
  },
  eslintConfigPrettier
);