#!/bin/bash

dnf install mariadb-server -y

vim /etc/my.cnf.d/mariadb-server.cnf

[mysqld]
skip-networking=1

systemctl enable --now mariadb
systemctl status mariadb

mariadb-secure-installation

mariadb -u root -p

EXIT;

CREATE DATABASE skynet;
SHOW DATABASES;
USE skynet;

CREATE TABLE student (
    ID INT PRIMARY KEY,
    NAME VARCHAR(50),
    EMAIL VARCHAR(100),
    Address VARCHAR(100)
);

SHOW TABLES;

USE skynet;
SHOW TABLES;
DESC student;

INSERT INTO student (ID, NAME, EMAIL, Address)
VALUES (1, 'kishor', 'k@gmail.com', 'nashik');

INSERT INTO student (ID, NAME, EMAIL, Address)
VALUES (2, 'radhika', 'r@gmail.com', 'pune');

SELECT * FROM student;

SELECT * FROM student WHERE name='radhika';

UPDATE student
SET id = 3
WHERE name = 'radhika';

SELECT * FROM student;

DELETE FROM student WHERE id = 1;

SELECT * FROM student;

SHOW TABLES;

CREATE USER 'alex'@'localhost' IDENTIFIED BY 'redhat';
CREATE USER 'susan'@'localhost' IDENTIFIED BY 'redhat';

SELECT user, password FROM mysql.user;

GRANT ALL PRIVILEGES ON skynet.* TO 'alex'@'localhost';

GRANT SELECT, UPDATE ON skynet.* TO 'susan'@'localhost';

SHOW GRANTS FOR 'alex'@'localhost';

REVOKE ALL PRIVILEGES ON skynet.* FROM 'alex'@'localhost';

SHOW GRANTS FOR 'alex'@'localhost';

DROP USER 'susan'@'localhost';

ALTER TABLE student ADD mob VARCHAR(20);

SELECT * FROM student;

DESC student;

ALTER TABLE student DROP mob;

DESCRIBE student;

mariadb-dump -u root -p skynet > /root/skynet.dump

ls -lh /root/skynet.dump

mariadb -u root -p skynet < /root/skynet.dump

SHOW TABLES;
SELECT * FROM student;

systemctl status mariadb

ALTER TABLE student DROP mob;


