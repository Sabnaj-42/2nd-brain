### documentdb user creation:   
```bash
 kubectl exec -it pg-demo-0 -n demo -- psql -U postgres -c "
  SELECT documentdb_api.create_user(
    '{
      \"createUser\": \"admin123\",
      \"pwd\": \"admin123\",
      \"roles\": [
        {\"role\": \"readAnyDatabase\", \"db\": \"admin\"}
      ]
    }'::documentdb_core.bson
  );
  "
```
### The Real Problem
When you called documentdb_api.create_user(), it:
- Created a PostgreSQL user admin123 ✓
- Did NOT register it in documentdb_api_catalog.roles ✗