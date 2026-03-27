# Troubleshooting

## Connection errors
Use `localhost` or `tcp:localhost,1433` if machine-name resolution fails.

## Password errors
Confirm the SQL login and password are valid.

## File path issues
Make sure `C:\Temp\DBA_Agent` exists or that the script account can create it.

## Empty sections
Some sections may be empty when:
- no current findings exist
- Query Store is not enabled
- blocking was not active at runtime
- observability tables have not been populated yet
