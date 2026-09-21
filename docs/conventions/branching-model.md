## Branching model

This repository should have these branches:

  * `main`    - used for production releases - was formerly called 'master'
  * `develop` - used as an integration branch - all feature-branches

```
-----o------------------o-------------o------ main
      \                /             /
      o---o---o---o---o-------o-----o-------- develop
        \   \     /                /
         \   o---o  feature-A     / 
          \                      /
            o---o---o---o---o---o  feature-B
```

All branches should branch away from `develop` and have specific naming - e.g.:

Here is a markdown table with typical prefixes for git branch names, along with their descriptions and examples:

| Branch Name    | Description       | Example                          |
|----------------|-------------------|----------------------------------|
| feature/       | New feature       | feature/add-login-functionality  |
| bugfix/        | Bug fix           | bugfix/fix-navigation-error      |
| hotfix/        | Critical fix      | hotfix/resolve-database-crash    |
| refactor/      | Code refactoring  | refactor/update-api-structure    |
| release/       | Release version   | release/v1.2.0                   |
| chore/         | Maintenance tasks | chore/clean-up-unused-files      |
| documentation/ | Documentation     | documentation/update-readme      |
| test/          | Testing-related   | test/add-unit-tests              |
| style/         | Styling changes   | style/update-form-styles         |
| experiment/    | Experimental      | experiment/try-new-algorithm     |

These prefixes help provide context and clarity to the purpose of each branch. For example, a branch  
named "feature/add-login-functionality" indicates that it is created to implement a new login feature.

If you're working on an issue it's a good idea to reference the issue-number within your branch.

For example, when working on a feature-request, that asks to implement a sidebar, you should name the branch:

    feature/issue-0004-add-side-navigation

So it's easy to see which branch addresses which issue.

<hr>

[Back to README](/README.md)
