# LabTech--Script-Backup
This powershell script (referred to as 'the script' from here on) will backup each LabTech script as an xml file. The script will also create a folder structure based on the ScriptID in LT. These exports will not include files from the transfer directory or any other scripts that are called (these xml files are NOT the same as doing an export from the Control Center). The last date and user modified will be prepended to the xml file as comments so that it can be used as version control.

The MySQL .NET connector is required.
https://dev.mysql.com/downloads/connector/net/6.9.html

If you want to utilize the git pushing feature, you need a git client
- The recommended git client can be installed via [chocolatey](https://chocolatey.org/docs/installation)
  - Once chocolatey is installed: `chocolatey install -y git.install`

This script can be run against any machine, but ideally one would use the LT script wrapper and set up a schedule to run against one of the LabTech backend servers directly: DB, App, Web

# Basic script features
The script must be run manually once to provide config parameters (db server, backup directory, etc). 
- The credentials are stored as a powershell credential object and can only be read in by the same account that created it. 
  - If you will be utilizing the LabTech script to schedule the backups, you will want to run the initial script execution as the service account for the labtech agent (likely the SYSTEM account). 
- This can be done either by logging in as the user or (as in the case of the SYSTEM account) by using [psexec](https://docs.microsoft.com/en-us/sysinternals/downloads/psexec)
The script also contains functionality to push the backup directory to a git repo. 
- The requirement is that the local git client is setup such that one can browse to the backup directory and successfully run
  - `git.exe pull`
  - `git.exe push`
  - `git.exe remote -v`
- There is a crude parameter to set this up using basic credentials in the https git URL: `-RebuildGitConfig`

# LT Script wrapper
The xml file in this repo is a full xml export of a script intended to give simpler scheduling and tracking than a windows scheduled task would. Simply import it and create a schedule against the machine you'd like to run the backups on. The powershell script is built to only export scripts that have changed since the last run, so the schedule can be as aggressive as required without much overhead.

Note that the powershell script has some setup, but the LT script should log if things aren't setup properly

# Originally created by [labtechconsulting](https://github.com/LabtechConsulting/LabTech--Script-Backup)
For more information please go to:

http://labtechconsulting.com/labtech-script-backup-and-version-control/
