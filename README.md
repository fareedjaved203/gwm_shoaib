# GWM Smart Waste Management - Oracle database

Submission files:

- `GWM_Database_Report.docx` the report (PDF copy alongside for checking layout)
- `sql/gwm_database.sql` the single executable SQL file

Run the SQL as a DBA (for example SYSTEM) connected to the pluggable database, Oracle 19c or later:

    sqlplus system@//host:1521/FREEPDB1 @sql/gwm_database.sql

It drops and recreates the GWM_OWNER schema, so it can be rerun. Set the schema password at the top of the file first.

Rebuilding the report after a change (needs Python with python-docx and Pillow, pandoc, and MS Word):

    python docs/make_screenshots.py   # from docs/sqlplus_output.txt, the captured SQL*Plus run
    python docs/build_report.py       # regenerates ERD sources, dictionary, dashboards, docx and pdf

ERD images are rendered from `docs/erd_*.mmd` with `@mermaid-js/mermaid-cli`.

Validated on `gvenzl/oracle-free:23-slim-faststart`.
