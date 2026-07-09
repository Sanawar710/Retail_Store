## How to Run

### 1. Clone the Repository

```bash
git clone https://github.com/Sanawar710/Retail_Store.git
```

Alternatively, download the repository as a ZIP file and extract it.

---

### 2. Open PostgreSQL in DBeaver

1. Launch **DBeaver**.
2. Create a new PostgreSQL connection if you haven't already.
3. Connect to your PostgreSQL server.
4. Create a new database (for example, `retail_store_db`).
5. Open the SQL Editor connected to this database.

---

### 3. Create the Database Schema

Run the `schema.sql` script.

This script creates:

- `retail_store` schema
- Source tables
- Primary keys
- Foreign keys

---

### 4. Import the CSV Files

For each table:

1. Expand your database in DBeaver.
2. Expand **Schemas** → **retail_store** → **Tables**.
3. Right-click the table.
4. Select **Import Data**.
5. Choose **CSV**.
6. Browse to the corresponding file inside the `data` folder.
7. Verify that the columns match.
8. Click **Next** until the wizard finishes.
9. Repeat for:
   - customers.csv
   - products.csv
   - orders.csv
   - payments.csv

---

### 5. Run the ETL Pipeline

Execute `queries.sql`.

This script performs:

- Data validation
- Data cleaning
- Staging
- Warehouse creation
- Business analytics

---

### 6. Explore the Results

After execution, you'll find:

- Source tables in the `retail_store` schema
- Cleaned tables in the `staging` schema
- Dimension and fact tables in the `warehouse` schema

You can execute the analytical queries at the end of `queries.sql` to generate business insights.