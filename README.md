**Note**: This project is currently highly experimental. Use at your own risk. 

# GetTheGist

`GetTheGist` makes it super simple to upload a single file out of a larger project as a GitHub gist. The gist means you can keep the rest of your codebase private, whilst bringing just that one file into public domain for teaching purposes. 

For example, updates to my [ZipSparsePairs](https://gist.github.com/benjaminmayo/734812a8f1e437f98d08381817bc38a2) gist are managed using `GetTheGist`.

# Installation

This project is built in Swift. Building the Swift Package produces an executable product that can be moved to `usr/local/bin`. I suggest renaming the executable to `get-the-gist`.

# Usage

`GetTheGist` stores API tokens in the Keychain. To authenticate your system, open a Terminal and execute the following command.

```
get-the-gist authenticate --user [username] --token [token] 

```
You can choose any `username`. The `token` can be generated from the [GitHub web console](https://github.com/settings/tokens/). Create a new personal access token, or re-use an existing one. Supply the `--user` argument to every subsequent invocation of the utility, passing the same username each time. 

After authenticating, you can then push a file as a gist. 

```
get-the-gist push --user [username] /path/to/file.swift
```
The location of the gist is stored as a source comment at the top of the file. This serves as a reminder that the file is uploaded to the web.

**Note**: `GetTheGist` creates gists as private by default. You can manually edit them in the GitHub web interface to make them public, and add a meaningful description.

Then, set up some kind of automation (perhaps a git hook) to run the same `push` command (complete with file path and username) when you make changes to your codebase. The `push` command will not update gists unless the actual content of the source code changes.

You can provide more than one file path (separated by spaces) to create and update more than one gist at a time. 
