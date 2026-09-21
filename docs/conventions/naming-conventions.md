# naming-conventions<!-- omit from toc -->

## Table of contents<!-- omit from toc -->

- [Introduction](#introduction)
- [General rules](#general-rules)
- [Naming conventions for specific languages](#naming-conventions-for-specific-languages)

## Introduction

`"There are only two hard things in computer science: cache invalidation and naming things" (Phil Karlton)` 

Naming things is a challenge - think twice before naming a repository, variable, function or whatever.  
If things have to be renamed this causes a lot of problems - for example:

   * Broken links/references - would not have happened, if the name was setup correctly and never changed, aye?
   * Problems with ambiguity - there was another variable that has the same name - now there's a collision
   * Missing clarity - people don't get what a variable is used for - because a not commonly known shortcode was used

Some reasons why naming is so important are:

- Readability and understandability of code
- Maintainability and ease of bug fixing, enhancements, and refactoring
- Collaboration and effective communication among team members
- Documentation generation and accuracy
- Avoidance of confusion and errors
- Reusability and modularity of code

## General rules

  * English only (this avoid problems with special chars)
  * no whitespaces (use hyphens ('-') instead)
  * no underscores (use hyphens ('-') instead)
  * avoid special chars except '-'

## Naming conventions for specific languages

If you are developing software, please stick to your language-specific established coding-styles.  
Here's a list of commonly used naming standards for specific coding languages.

  * PowerShell - https://poshcode.gitbook.io/powershell-practice-and-style/style-guide/naming-conventions
  * C# Coding Style - https://github.com/dotnet/runtime/blob/main/docs/coding-guidelines/coding-style.md
  * ...

<hr>

[Back to README](/README.md)