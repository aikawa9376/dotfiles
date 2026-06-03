local ls = require("luasnip")

local s = ls.snippet
local t = ls.text_node
local i = ls.insert_node
local c = ls.choice_node

local sql = {
  s("createt", {
    t("CREATE TABLE "),
    i(1, "tableName"),
    t({ " (", "\t" }),
    i(2, "attribute(s)"),
    t({ "", ");" }),
  }),

  s("createti", {
    t("CREATE TABLE IF NOT EXISTS "),
    i(1, "tableName"),
    t({ " (", "\t" }),
    i(2, "attribute(s)"),
    t({ "", ");" }),
  }),

  s("created", {
    t("CREATE DATABASE "),
    i(1, "name"),
    t(";"),
  }),

  s("createdi", {
    t("CREATE DATABASE IF NOT EXISTS "),
    i(1, "name"),
    t(";"),
  }),

  s("insert", {
    t("INSERT INTO "),
    i(1, "tableName"),
    t({ " (", "\t" }),
    i(2, "attribute(s)"),
    t({ "", ") VALUES ( " }),
    i(3, "values"),
    t(" )"),
  }),

  s("dropt", {
    t("DROP TABLE "),
    i(1, "tableName"),
    t(";"),
  }),

  s("dropd", {
    t("DROP DATABASE "),
    i(1, "dbName"),
    t(";"),
  }),

  s("dropti", {
    t("DROP TABLE IF EXISTS "),
    i(1, "tableName"),
    t(";"),
  }),

  s("dropdi", {
    t("DROP DATABASE IF EXISTS "),
    i(1, "dbName"),
    t(";"),
  }),

  s("showt", {
    t("SHOW TABLES;"),
  }),

  s("showd", {
    t("SHOW DATABASES;"),
  }),

  -- Jump order adjusted: table -> columns
  s("select", {
    t("SELECT "),
    i(2, "attribute(s)"),
    t(" FROM "),
    i(1, "tableName"),
    t(";"),
  }),

  -- Jump order adjusted: table -> columns
  s("selectd", {
    t("SELECT DISTINCT "),
    i(2, "attribute(s)"),
    t({ "", "\tFROM " }),
    i(1, "tableName"),
    t(";"),
  }),

  -- Jump order adjusted: table -> columns
  s("selectw", {
    t("SELECT "),
    i(2, "attribute(s)"),
    t({ "", "\tFROM " }),
    i(1, "tableName"),
    t({ "", "\tWHERE " }),
    i(3, "condition"),
    t(";"),
  }),

  -- Jump order adjusted: table -> columns
  s("selector", {
    t("SELECT "),
    i(2, "attribute(s)"),
    t({ "", "\tFROM " }),
    i(1, "tableName"),
    t({ "", "\tORDER BY " }),
    i(3, "attribute(s)"),
    t(" "),
    c(4, { t("ASC"), t("DESC") }),
    t(";"),
  }),

  s("updatet", {
    t("UPDATE "),
    i(1, "tableName"),
    t({ "", "\tSET " }),
    i(2, "attribute(s)"),
    t({ "", "\tWHERE " }),
    i(3, "condition"),
    t(";"),
  }),

  s("delete", {
    t("DELETE FROM "),
    i(1, "tableName"),
    t({ "", "\tWHERE " }),
    i(2, "condition"),
    t(";"),
  }),

  s("altert", {
    t("ALTER TABLE "),
    i(1, "tableName"),
    t({ "", "\t " }),
    i(2, "intructions"),
    t(";"),
  }),

  s("alterad", {
    t("ALTER TABLE "),
    i(1, "tableName"),
    t({ "", "\tADD COLUMN " }),
    i(2, "col_name"),
    t(";"),
  }),

  s("alteraf", {
    t("ALTER TABLE "),
    i(1, "tableName"),
    t({ "", "\tADD COLUMN " }),
    i(2, "col_name"),
    t({ "", "\tAFTER " }),
    i(3, "col_name"),
    t(";"),
  }),

  s("alterdb", {
    t("ALTER DATABASE "),
    i(1, "dbName"),
    t({ "", "\tCHARACTER SET " }),
    i(2, "charset"),
    t({ "", "\tCOLLATE " }),
    i(3, "utf8_unicode_ci"),
    t(";"),
  }),

  -- Jump order adjusted: table -> columns
  s("ijoin", {
    t("SELECT "),
    i(2, "attribute(s)"),
    t({ "", "\tFROM " }),
    i(1, "tableName"),
    t({ "", "\tINNER JOIN " }),
    i(3, "tableName2"),
    t({ "", "\tON " }),
    i(4, "match"),
    t(";"),
  }),

  -- Jump order adjusted: table -> columns
  s("rjoin", {
    t("SELECT "),
    i(2, "attribute(s)"),
    t({ "", "\tFROM " }),
    i(1, "tableName"),
    t({ "", "\tRIGHT JOIN " }),
    i(3, "tableName2"),
    t({ "", "\tON " }),
    i(4, "match"),
    t(";"),
  }),

  -- Jump order adjusted: table -> columns
  s("ljoin", {
    t("SELECT "),
    i(2, "attribute(s)"),
    t({ "", "\tFROM " }),
    i(1, "tableName"),
    t({ "", "\tLEFT JOIN " }),
    i(3, "tableName2"),
    t({ "", "\tON " }),
    i(4, "match"),
    t(";"),
  }),

  -- Jump order adjusted: table -> columns
  s("fjoin", {
    t("SELECT "),
    i(2, "attribute(s)"),
    t({ "", "\tFROM " }),
    i(1, "tableName"),
    t({ "", "\tFULL JOIN OUTER " }),
    i(3, "tableName2"),
    t({ "", "\tON " }),
    i(4, "match"),
    t({ "", "\tWHERE " }),
    i(5, "condition"),
    t(";"),
  }),

  -- Jump order adjusted: table -> columns (for each SELECT)
  s("union", {
    t("SELECT "),
    i(2, "attribute(s)"),
    t(" FROM "),
    i(1, "tableName"),
    t({ "", "UNION", "SELECT " }),
    i(4, "attribute(s)"),
    t(" FROM "),
    i(3, "tableName2"),
    t(";"),
  }),

  -- Jump order adjusted: table -> columns (for each SELECT)
  s("uniona", {
    t("SELECT "),
    i(2, "attribute(s)"),
    t(" FROM "),
    i(1, "tableName"),
    t({ "", "UNION ALL", "SELECT " }),
    i(4, "attribute(s)"),
    t(" FROM "),
    i(3, "tableName2"),
    t(";"),
  }),

  -- Jump order adjusted: table -> columns
  s("groupb", {
    t("SELECT "),
    i(2, "attribute(s)"),
    t({ "", "\tFROM " }),
    i(1, "tableName"),
    t({ "", "\tGROUP BY " }),
    i(3, "attribute(s)"),
    t(";"),
  }),

  s("bakupd", {
    t("BACKUP DATABASE "),
    i(1, "dbName"),
    t({ "", "\tTO DISK " }),
    i(2, "filepath"),
    t(";"),
  }),

  s("bakupdw", {
    t("BACKUP DATABASE "),
    i(1, "dbName"),
    t({ "", "\tTO DISK " }),
    i(2, "filepath"),
    t({ "", "\tWITH " }),
    i(3, "DIFERENTIAL"),
    t(";"),
  }),

  s("primaryk", {
    t("PRIMARY KEY("),
    i(1, "attribute"),
    t(")"),
  }),

  s("primarykc", {
    t("CONSTRAINT "),
    i(1, "attribute"),
    t(" PRIMARY KEY("),
    i(2, "attribute(s)"),
    t(")"),
  }),

  s("foreignk", {
    t("FOREIGN KEY("),
    i(1, "attribute"),
    t(") REFERENCES "),
    i(2, "tableName"),
    t("("),
    i(3, "attribute"),
    t(")"),
  }),

  s("foreignkc", {
    t("CONSTRAINT "),
    i(1, "attribute"),
    t(" FOREIGN KEY ("),
    i(2, "attribute(s)"),
    t({ ")", "\tREFERENCES " }),
    i(3, "tableName"),
    t("("),
    i(4, "attribute"),
    t(")"),
  }),

  s("check", {
    t("CHECK ( "),
    i(1, "condition"),
    t(" )"),
  }),

  s("createuser", {
    t("CREATE USER '"),
    i(1, "username"),
    t("'@'"),
    i(2, "localhost"),
    t("' IDENTIFIED BY '"),
    i(3, "password"),
    t("';"),
  }),

  s("deleteuser", {
    t("DELETE FROM mysql.user WHERE user = '"),
    i(1, "userName"),
    t("';"),
  }),

  s("grantuser", {
    t("GRANT ALL PRIVILEGES ON "),
    i(1, "db"),
    t("."),
    i(2, "tb"),
    t(" TO '"),
    i(3, "user_name"),
    t("'@'"),
    i(4, "localhost"),
    t("';"),
  }),
}

return sql
