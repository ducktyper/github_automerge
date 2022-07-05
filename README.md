GitHub Automerge automatically merges your approved pull request handling the rebase from the `main` branch and waiting for CI for you.

The whole process is done on a separate cloned repo under `./projects` so you can continually develop new features while the auto-merge is running.
The merge is done as the fast forward merge into the main branch if the pull request has only one commit.
Otherwise, use the GitHub merge that creates a merge commit.

Instruction:
1. Clone this repo
    ```
    git clone git@github.com:ducktyper/github_automerge.git
    ```
3. Create a personal access token with `repo` permission on GitHub by accessing https://github.com/settings/tokens
2. Copy `.env.example` under the same folder replacing `example` to any name (e.g. .env.cool_project)
4. Fill the values on the new env file
5. Merge your pull request by running the command below
    ```
    ./merge.sh cool_project branch-name-the-pull-request-is-created-with
    ```

NOTE:
* The auto-merge fails if the rebase fails with conflicts
* The feature branch on your local development repo will be outdated when the auto-merge force pushes the feature branch to GitHub after rebasing from the `main` branch
* Do not run `merge.sh` multiple times concurrently
