# forgejo_backup

**Simple base set of scripts to init, backup, restore your forgejo server**

You want a lightweight git hosting on your own Linux server?  
Forgejo + PostgreSQL in Docker is perfect for that — low resources, fast, open-source.

Repo goal: make setup, backup and restore easier.

Tested on [ALT Server](https://www.basealt.ru/) and WSL2 with Ubuntu

The setup assumes two Docker containers:
- forgejo   (you name it) 
- postgres  (you name it)


## Repository Contents

| Script                        | Purpose                                      |
|-------------------------------|----------------------------------------------|
| `backup_forgejo.sh`           | Create full Forgejo dump + rotation backups  |
| `restore_forgejo.sh`          | Restore from ZIP dump (DB + files)           |

## Backup Forgejo (backup_forgejo.sh)

Creates a full `forgejo dump` ZIP file and copies it to the host

### Usage

```bash
./backup_forgejo.sh [OPTIONS]

Options:
--container NAME     Docker container name (default: forgejo_serv)
--backup-dir PATH    Where to store backups (default: /home/gelez/backups)
--config-path PATH   Path to app.ini inside container (default: /data/gitea/conf/app.ini)
--user USER          Run dump as this user (default: git)
--keep-days DAYS     Delete backups older than N days (default: 7)
--monthly-keep       Keep backups from the 1st day of each month (default: yes)
-h, --help           Show help
```

### Example

```babash
./backup_forgejo.sh --container forgejo_serv --backup-dir /your/backup/path/for/forgejo
```

Daily backup file: *18-02-2026-forgejo.zip*

Old forgejo backup files are automatically deleted (except monthly ones on the 1st) (check `--monthly-keep`).

### Add to cron
Dont forget to make it executable
`chmod +x backup_forgejo.sh`
and setup to cron (change paths to your own ones):

`(crontab -l 2>/dev/null; echo "@daily /path/to/backup_forgejo.sh >> /var/log/backup_forgejo.log 2>&1") | crontab -`

## Dont like those scripts? 

You maybe right... just copy data folder that linked to the container... then pgdump postgres ... and rsync

Or maybe something else, [check this out](https://codeberg.org/Codeberg-Infrastructure/forgejo-backup) 
