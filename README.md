# Overview
CWA (formally LabTech) is a powerful RMM with many options to do base-level customizations. With that comes many configurations that can be easily changed (or broken). Often times it is non-trivial to identify and fix these things. As with any system, fixing something that breaks is usually a matter of answering "what changed". That's where this system comes in. While it can do basic exports of the various components of the CWA system to a local git repo, its main benefit is in pushing to an external git repo. Version comparisions of the CWA system makes tracing out changes a breeze.

# CWA-Git-Backup
This powershell script (referred to as 'the backup script' from here on) will backup various components of the CWA system:
 - Each CWA script as an xml file. The backup script will also create a folder structure based on the ScriptID in LT. 
     - These exports will not include files from the transfer directory or any other scripts that are called (these xml files are NOT the same as doing an export from the Control Center). The last date and user modified will be prepended to the xml file as comments so that it can be used as version control.
 - LTShare
  - Group commits based on file extention
 - Search definitions
  - Preserve folder structure
 - Internal monitors
 - Groups
  - Meta defintions (template properties, permissions, etc)
  - Remote monitors
  - Custom internal monitor configs
  - Scheduled scripts
 - DB metadata
  - We have some custom tables that backing up the schema would be useful. Perhaps a simple backup of all the table schemas would be simple enough
  - Obviously the triggers, functions, views, etc from your original post
 - (extra credit) User Classes
  - This would require some work similar to what was done to decode script actions, but I think it would be useful to have at some point

The MySQL .NET connector is required.
https://dev.mysql.com/downloads/connector/net/6.9.html


This script can be run against any machine, but ideally one would use the CWA script wrapper and set up a schedule to run against one of the LabTech backend servers directly: DB, App, Web

# Basic script features
The script must be run manually once to provide config parameters (db server, backup directory, etc). 
- The credentials are stored as a powershell credential object and can only be read in by the same account that created it
  - if it's going to be run by CWA script, this is likely the SYSTEM account (or whichever account the service runs as)
- This can be done either by logging in as the user or (as in the case of the SYSTEM account) by using [psexec](https://docs.microsoft.com/en-us/sysinternals/downloads/psexec)

The script also contains functionality to push the backup directory to an external git repo. 
 - The requirement is that the local git client is setup such that one can browse to the backup directory and successfully run
  - `git.exe pull`
  - `git.exe push`
  - `git.exe remote -v`
If you want to utilize the git pushing feature, you need a git client
 - The recommended git client can be installed via [chocolatey](https://chocolatey.org/docs/installation)
  - Once chocolatey is installed: `chocolatey install -y git.install`
 - Once git is installed, [ssh keys should be configured for simplicity](http://guides.beanstalkapp.com/version-control/git-on-windows.html#installing-ssh-keys)

- There is a crude parameter to set this up using basic credentials in the https git URL: `-RebuildGitConfig`

# CWA Script wrapper
The xml file in this repo is a full xml export of a script intended to give simpler scheduling and tracking than a windows scheduled task would. Simply import it and create a schedule against the machine you'd like to run the backups on. The powershell script is built to only export scripts that have changed since the last run, so the schedule can be as aggressive as required without much overhead.

Note that the powershell script has some setup, but the LT script should log if things aren't setup properly

# Originally created by [labtechconsulting](https://github.com/LabtechConsulting/LabTech--Script-Backup)
For more information please go to:

http://labtechconsulting.com/labtech-script-backup-and-version-control/
