<!-- /qompassai/rose.nvim/README.md -->
<!-- ---------------------------- -->
<!-- Copyright (C) 2025 Qompass AI, All rights reserved -->

<h3> rose.nvim </h3>

<h2> Your quality AI menu </h2>
![Repository Views](https://komarev.com/ghpvc/?username=qompassai-rose.nvim)
![GitHub all releases](https://img.shields.io/github/downloads/qompassai/rose.nvim/total?style=flat-square)
# Requires

- [Qompass Diver](https://github.com/qompassai/Diver)
- [Curl](https://curl.se/)
- [CMake](https://cmake.org)

# Optional
- Perplexity API Key
- Groq API Key
- OpenAI Key
- Mistral API Key
- Anthropic API Key
- X.AI API key
- NVIDIA API Key

# How to stay updated

To get updates once this on your computer, you have two options:

1. [**Using HTTPS (Most Common)**](#using-https-most-common)
2. [**Using SSH (Advanced)**](#using-ssh-advanced)

- **Either** option requires[git](#how-to-install-git) to be installed:

### Using HTTPS (Most Common)

This option is best if:

    * You’re new to GitHub
    * You like to keep things simple.
    * You haven't set up SSH/GPG keys for Github.
    * You don't have the Github CLI

- MacOS | Linux | Microsoft WSL

```bash
git clone --depth 1 https://github.com/qompassai/Equator.git
git remote add upstream https://github.com/qompassai/Equator.git
git fetch upstream
git checkout main
git merge upstream/main
```

Note: You only need to run the clone command **once**. After that, go to [3. Getting Updates](#getting-updates) to keep your local repository up-to-date.

2. **Using SSH(Advanced)**:

-  MacOS | Linux | Microsoft WSL **with** [GitHub CLI (gh)](https://github.com/cli/cli#installation)

```bash
gh repo clone qompassai/Equator
git remote add upstream https://github.com/qompassai/Equator.git
git fetch upstream
git checkout main
git merge upstream/main
```

This option is best if you:

    * are not new to Github
    * You want to add a new technical skill
    * You're comfortable with the terminal/CLI, or want to be
    * You have SSH/GPG set up
    * You're

Note: You only need to run the clone command **once**. After that, go to [3. Getting Updates](#getting-updates) to keep your local repository up-to-date.

3. Getting updates

- **After** cloning locally, use the following snippet below to get the latest updates:

- MacOS | Linux | Microsoft WSL

- Option 1:
**This will **overwrite** any local changes you've made**

```bash
git fetch upstream
git checkout main
git merge upstream/main
```

-Option 2:
**To keep your local changes and still get the updates**

```bash
git stash
git fetch upstream
git checkout main
git merge upstream/main
git stash pop
```

