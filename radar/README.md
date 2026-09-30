# radar state

`seen.txt` holds every repo the radar has already reported, one `owner/repo`
per line, so a second sweep is quiet by design. The scheduled workflow commits
it back after each run.

Delete a line to have that repo resurface. Delete the file to start over.
