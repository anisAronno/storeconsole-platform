-- Focus Platform — Database Initialization
-- Creates all 3 databases on first MySQL startup.

CREATE DATABASE IF NOT EXISTS focus_backend
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;

CREATE DATABASE IF NOT EXISTS focus_web_app
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;

CREATE DATABASE IF NOT EXISTS focus_old_web
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;
