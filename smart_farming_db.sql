-- phpMyAdmin SQL Dump
-- version 5.2.2
-- https://www.phpmyadmin.net/
--
-- Host: localhost:3306
-- Waktu pembuatan: 27 Des 2025 pada 00.00
-- Versi server: 8.0.30
-- Versi PHP: 8.1.10

SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";
START TRANSACTION;
SET time_zone = "+00:00";


/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!40101 SET NAMES utf8mb4 */;

--
-- Database: `smart_farming_db`
--

DELIMITER $$
--
-- Prosedur
--
CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_backup_critical_data` (IN `p_backup_name` VARCHAR(100))   BEGIN
    DECLARE v_backup_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP;
    DECLARE v_backup_table VARCHAR(100);
    
    -- Create backup table for sensor_data
    SET v_backup_table = CONCAT('backup_sensor_data_', DATE_FORMAT(v_backup_time, '%Y%m%d_%H%i%s'));
    SET @sql = CONCAT('CREATE TABLE ', v_backup_table, ' AS SELECT * FROM sensor_data');
    PREPARE stmt FROM @sql;
    EXECUTE stmt;
    DEALLOCATE PREPARE stmt;
    
    -- Create backup table for sensor_devices
    SET v_backup_table = CONCAT('backup_sensor_devices_', DATE_FORMAT(v_backup_time, '%Y%m%d_%H%i%s'));
    SET @sql = CONCAT('CREATE TABLE ', v_backup_table, ' AS SELECT * FROM sensor_devices');
    PREPARE stmt FROM @sql;
    EXECUTE stmt;
    DEALLOCATE PREPARE stmt;
    
    -- Log the backup
    INSERT INTO audit_logs (action_type, table_name, new_values)
    VALUES ('BACKUP', 'system', 
            JSON_OBJECT(
                'backup_name', p_backup_name,
                'backup_time', v_backup_time,
                'created_by', CURRENT_USER()
            ));
    
    SELECT 
        'success' as status,
        CONCAT('Backup created: ', p_backup_name) as message,
        v_backup_time as backup_time;
END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_check_sensor_alerts` (IN `p_suhu` DECIMAL(5,2), IN `p_kelembapan` DECIMAL(5,2), IN `p_sensor_id` INT)   BEGIN
    DECLARE v_threshold_name VARCHAR(100);
    DECLARE v_min_suhu, v_max_suhu, v_min_kelembapan, v_max_kelembapan DECIMAL(5,2);
    
    -- Get applicable threshold (using first threshold for demo)
    SELECT threshold_name, min_suhu, max_suhu, min_kelembapan, max_kelembapan
    INTO v_threshold_name, v_min_suhu, v_max_suhu, v_min_kelembapan, v_max_kelembapan
    FROM sensor_thresholds 
    LIMIT 1;
    
    -- Check temperature alerts
    IF p_suhu > v_max_suhu THEN
        INSERT INTO sensor_alerts (sensor_id, alert_type, alert_message, alert_level)
        VALUES (p_sensor_id, 'TEMPERATURE_HIGH', 
                CONCAT('Suhu ', p_suhu, '°C melebihi batas maksimum ', v_max_suhu, '°C'), 
                'HIGH');
    ELSEIF p_suhu < v_min_suhu THEN
        INSERT INTO sensor_alerts (sensor_id, alert_type, alert_message, alert_level)
        VALUES (p_sensor_id, 'TEMPERATURE_LOW', 
                CONCAT('Suhu ', p_suhu, '°C dibawah batas minimum ', v_min_suhu, '°C'), 
                'HIGH');
    END IF;
    
    -- Check humidity alerts
    IF p_kelembapan > v_max_kelembapan THEN
        INSERT INTO sensor_alerts (sensor_id, alert_type, alert_message, alert_level)
        VALUES (p_sensor_id, 'HUMIDITY_HIGH', 
                CONCAT('Kelembapan ', p_kelembapan, '% melebihi batas maksimum ', v_max_kelembapan, '%'), 
                'MEDIUM');
    ELSEIF p_kelembapan < v_min_kelembapan THEN
        INSERT INTO sensor_alerts (sensor_id, alert_type, alert_message, alert_level)
        VALUES (p_sensor_id, 'HUMIDITY_LOW', 
                CONCAT('Kelembapan ', p_kelembapan, '% dibawah batas minimum ', v_min_kelembapan, '%'), 
                'MEDIUM');
    END IF;
END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_clean_old_data` (IN `p_days_to_keep` INT)   BEGIN
    DECLARE v_cutoff_date DATE;
    DECLARE v_deleted_count INT DEFAULT 0;
    
    SET v_cutoff_date = CURDATE() - INTERVAL p_days_to_keep DAY;
    
    -- Delete old raw data
    DELETE FROM sensor_data 
    WHERE DATE(waktu) < v_cutoff_date;
    
    SET v_deleted_count = ROW_COUNT();
    
    -- Archive deleted count
    INSERT INTO audit_logs (action_type, table_name, record_id, new_values)
    VALUES ('DATA_CLEANUP', 'sensor_data', v_deleted_count, 
            JSON_OBJECT('cutoff_date', v_cutoff_date, 'deleted_count', v_deleted_count));
    
    SELECT 
        'success' as status,
        CONCAT(v_deleted_count, ' records deleted') as message,
        v_cutoff_date as cutoff_date;
END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_export_data_to_csv` (IN `p_start_date` DATE, IN `p_end_date` DATE)   BEGIN
    DECLARE v_export_path VARCHAR(255);
    
    SET v_export_path = CONCAT('/var/lib/mysql-files/export_sensor_', 
                               DATE_FORMAT(NOW(), '%Y%m%d_%H%i%s'), '.csv');
    
    SET @sql = CONCAT(
        "SELECT 'id','suhu','kelembapan','waktu','temperature_status','humidity_status'
         UNION ALL
         SELECT 
            id,
            suhu,
            kelembapan,
            waktu,
            CASE 
                WHEN suhu < 20 THEN 'Dingin'
                WHEN suhu BETWEEN 20 AND 30 THEN 'Optimal'
                WHEN suhu > 30 THEN 'Panas'
            END,
            CASE 
                WHEN kelembapan < 60 THEN 'Kering'
                WHEN kelembapan BETWEEN 60 AND 80 THEN 'Ideal'
                WHEN kelembapan > 80 THEN 'Lembab'
            END
         FROM sensor_data
         WHERE DATE(waktu) BETWEEN '", p_start_date, "' AND '", p_end_date, "'
         INTO OUTFILE '", v_export_path, "'
         FIELDS TERMINATED BY ','
         ENCLOSED BY '\"'
         LINES TERMINATED BY '\\n'"
    );
    
    PREPARE stmt FROM @sql;
    EXECUTE stmt;
    DEALLOCATE PREPARE stmt;
    
    SELECT 
        'success' as status,
        CONCAT('Data exported to: ', v_export_path) as message,
        v_export_path as file_path;
END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_generate_hourly_aggregation` ()   BEGIN
    INSERT INTO sensor_data_hourly (date_hour, avg_suhu, min_suhu, max_suhu, 
                                    avg_kelembapan, min_kelembapan, max_kelembapan, data_count)
    SELECT 
        DATE_FORMAT(waktu, '%Y-%m-%d %H:00:00') as date_hour,
        ROUND(AVG(suhu), 2) as avg_suhu,
        ROUND(MIN(suhu), 2) as min_suhu,
        ROUND(MAX(suhu), 2) as max_suhu,
        ROUND(AVG(kelembapan), 2) as avg_kelembapan,
        ROUND(MIN(kelembapan), 2) as min_kelembapan,
        ROUND(MAX(kelembapan), 2) as max_kelembapan,
        COUNT(*) as data_count
    FROM sensor_data
    WHERE waktu >= NOW() - INTERVAL 1 HOUR
      AND waktu < DATE_FORMAT(NOW(), '%Y-%m-%d %H:00:00')
    GROUP BY DATE_FORMAT(waktu, '%Y-%m-%d %H:00:00')
    ON DUPLICATE KEY UPDATE
        avg_suhu = VALUES(avg_suhu),
        min_suhu = VALUES(min_suhu),
        max_suhu = VALUES(max_suhu),
        avg_kelembapan = VALUES(avg_kelembapan),
        min_kelembapan = VALUES(min_kelembapan),
        max_kelembapan = VALUES(max_kelembapan),
        data_count = VALUES(data_count);
END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_get_latest_readings` (IN `p_limit` INT)   BEGIN
    SELECT 
        id,
        suhu,
        kelembapan,
        DATE_FORMAT(waktu, '%Y-%m-%d %H:%i:%s') as waktu_formatted,
        CASE 
            WHEN suhu < 20 THEN 'Dingin'
            WHEN suhu BETWEEN 20 AND 30 THEN 'Normal'
            WHEN suhu > 30 THEN 'Panas'
        END as suhu_status,
        CASE 
            WHEN kelembapan < 60 THEN 'Kering'
            WHEN kelembapan BETWEEN 60 AND 80 THEN 'Ideal'
            WHEN kelembapan > 80 THEN 'Lembab'
        END as kelembapan_status
    FROM sensor_data
    ORDER BY waktu DESC
    LIMIT p_limit;
END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_get_sensor_stats` (IN `p_hours` INT)   BEGIN
    DECLARE v_start_time TIMESTAMP;
    
    SET v_start_time = NOW() - INTERVAL p_hours HOUR;
    
    SELECT 
        COUNT(*) as total_data,
        ROUND(AVG(suhu), 2) as avg_suhu,
        ROUND(MIN(suhu), 2) as min_suhu,
        ROUND(MAX(suhu), 2) as max_suhu,
        ROUND(AVG(kelembapan), 2) as avg_kelembapan,
        ROUND(MIN(kelembapan), 2) as min_kelembapan,
        ROUND(MAX(kelembapan), 2) as max_kelembapan,
        MAX(waktu) as last_update
    FROM sensor_data
    WHERE waktu >= v_start_time;
END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_insert_sensor_data` (IN `p_suhu` DECIMAL(5,2), IN `p_kelembapan` DECIMAL(5,2))   BEGIN
    DECLARE v_is_valid BOOLEAN DEFAULT TRUE;
    DECLARE v_error_message VARCHAR(255);
    
    -- Validasi range suhu
    IF p_suhu < -10 OR p_suhu > 50 THEN
        SET v_is_valid = FALSE;
        SET v_error_message = CONCAT('Suhu ', p_suhu, '°C diluar range normal pertanian (-10°C s/d 50°C)');
    END IF;
    
    -- Validasi range kelembapan
    IF p_kelembapan < 0 OR p_kelembapan > 100 THEN
        SET v_is_valid = FALSE;
        SET v_error_message = CONCAT('Kelembapan ', p_kelembapan, '% diluar range (0% s/d 100%)');
    END IF;
    
    IF v_is_valid THEN
        -- Insert data sensor
        INSERT INTO sensor_data (suhu, kelembapan) 
        VALUES (p_suhu, p_kelembapan);
        
        -- Check for alerts
        CALL sp_check_sensor_alerts(p_suhu, p_kelembapan, LAST_INSERT_ID());
        
        -- Return success
        SELECT 
            'success' as status,
            'Data sensor berhasil disimpan' as message,
            LAST_INSERT_ID() as sensor_id;
    ELSE
        -- Return error
        SELECT 
            'error' as status,
            v_error_message as message,
            NULL as sensor_id;
    END IF;
END$$

DELIMITER ;

-- --------------------------------------------------------

--
-- Struktur dari tabel `api_tokens`
--

CREATE TABLE `api_tokens` (
  `token_id` int NOT NULL,
  `user_id` int DEFAULT NULL,
  `token` varchar(255) COLLATE utf8mb4_unicode_ci NOT NULL,
  `token_name` varchar(100) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `expires_at` timestamp NULL DEFAULT NULL,
  `last_used` timestamp NULL DEFAULT NULL,
  `is_active` tinyint(1) DEFAULT '1',
  `created_at` timestamp NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Struktur dari tabel `audit_logs`
--

CREATE TABLE `audit_logs` (
  `log_id` int NOT NULL,
  `user_id` int DEFAULT NULL,
  `action_type` varchar(50) COLLATE utf8mb4_unicode_ci NOT NULL COMMENT 'CREATE, UPDATE, DELETE, LOGIN, etc',
  `table_name` varchar(50) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `record_id` int DEFAULT NULL,
  `old_values` json DEFAULT NULL,
  `new_values` json DEFAULT NULL,
  `ip_address` varchar(45) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `user_agent` text COLLATE utf8mb4_unicode_ci,
  `created_at` timestamp NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data untuk tabel `audit_logs`
--

INSERT INTO `audit_logs` (`log_id`, `user_id`, `action_type`, `table_name`, `record_id`, `old_values`, `new_values`, `ip_address`, `user_agent`, `created_at`) VALUES
(1, NULL, 'DATA_CLEANUP', 'sensor_data', 0, NULL, '{\"cutoff_date\": \"2025-09-27\", \"deleted_count\": 0}', NULL, NULL, '2025-12-26 10:08:15'),
(2, NULL, 'CALIBRATION_CHECK', 'sensor_devices', NULL, NULL, '{\"checked_at\": \"2025-12-26 17:08:15.000000\", \"devices_updated\": 5}', NULL, NULL, '2025-12-26 10:08:15');

-- --------------------------------------------------------

--
-- Struktur dari tabel `farming_zones`
--

CREATE TABLE `farming_zones` (
  `zone_id` int NOT NULL,
  `zone_name` varchar(100) COLLATE utf8mb4_unicode_ci NOT NULL COMMENT 'Nama zona (ex: GreenHouse A, Kebun Sayur)',
  `zone_type` enum('GREENHOUSE','OPEN_FIELD','HYDROPONIC','NURSERY') COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `area_size` decimal(10,2) DEFAULT NULL COMMENT 'Luas area dalam meter persegi',
  `soil_type` varchar(50) COLLATE utf8mb4_unicode_ci DEFAULT NULL COMMENT 'Jenis tanah',
  `crop_type` varchar(100) COLLATE utf8mb4_unicode_ci DEFAULT NULL COMMENT 'Jenis tanaman'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data untuk tabel `farming_zones`
--

INSERT INTO `farming_zones` (`zone_id`, `zone_name`, `zone_type`, `area_size`, `soil_type`, `crop_type`) VALUES
(1, 'Greenhouse A', 'GREENHOUSE', 200.00, 'Tanah Organik', 'Tomat Cherry'),
(2, 'Greenhouse B', 'GREENHOUSE', 150.00, 'Tanah Berpasir', 'Cabai Rawit'),
(3, 'Kebun Sayur Utama', 'OPEN_FIELD', 500.00, 'Tanah Liat', 'Bayam & Kangkung'),
(4, 'Nursery Bibit', 'NURSERY', 50.00, 'Tanah Campuran', 'Bibit Sayuran'),
(5, 'Hidroponik Rakit', 'HYDROPONIC', 100.00, 'Air Nutrisi', 'Selada & Pakcoy');

-- --------------------------------------------------------

--
-- Struktur dari tabel `sensor_alerts`
--

CREATE TABLE `sensor_alerts` (
  `alert_id` int NOT NULL,
  `sensor_id` int DEFAULT NULL,
  `alert_type` enum('TEMPERATURE_HIGH','TEMPERATURE_LOW','HUMIDITY_HIGH','HUMIDITY_LOW','DEVICE_OFFLINE') COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `alert_message` text COLLATE utf8mb4_unicode_ci,
  `alert_level` enum('LOW','MEDIUM','HIGH','CRITICAL') COLLATE utf8mb4_unicode_ci DEFAULT 'MEDIUM',
  `is_resolved` tinyint(1) DEFAULT '0',
  `resolved_at` timestamp NULL DEFAULT NULL,
  `created_at` timestamp NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Struktur dari tabel `sensor_data`
--

CREATE TABLE `sensor_data` (
  `id` int NOT NULL,
  `suhu` decimal(5,2) NOT NULL COMMENT 'Suhu dalam derajat Celsius',
  `kelembapan` decimal(5,2) NOT NULL COMMENT 'Kelembapan dalam persen',
  `waktu` timestamp NULL DEFAULT CURRENT_TIMESTAMP COMMENT 'Waktu pencatatan data'
) ;

--
-- Dumping data untuk tabel `sensor_data`
--

INSERT INTO `sensor_data` (`id`, `suhu`, `kelembapan`, `waktu`) VALUES
(1, 25.50, 65.00, '2025-12-26 09:55:41'),
(2, 26.00, 62.50, '2025-12-26 09:45:41'),
(3, 24.80, 68.00, '2025-12-26 09:35:41'),
(4, 25.20, 66.50, '2025-12-26 09:25:41'),
(5, 26.50, 60.00, '2025-12-26 09:15:41'),
(6, 25.00, 70.00, '2025-12-26 09:05:41'),
(7, 22.50, 75.00, '2025-12-25 10:05:41'),
(8, 23.00, 72.50, '2025-12-25 09:35:41'),
(9, 21.80, 78.00, '2025-12-25 09:05:41'),
(10, 24.00, 68.50, '2025-12-24 10:05:41'),
(11, 25.50, 65.00, '2025-12-24 09:35:41');

--
-- Trigger `sensor_data`
--
DELIMITER $$
CREATE TRIGGER `trg_after_sensor_insert` AFTER INSERT ON `sensor_data` FOR EACH ROW BEGIN
    -- Update hourly aggregation
    INSERT INTO sensor_data_hourly (date_hour, avg_suhu, min_suhu, max_suhu, 
                                    avg_kelembapan, min_kelembapan, max_kelembapan, data_count)
    VALUES (
        DATE_FORMAT(NEW.waktu, '%Y-%m-%d %H:00:00'),
        NEW.suhu,
        NEW.suhu,
        NEW.suhu,
        NEW.kelembapan,
        NEW.kelembapan,
        NEW.kelembapan,
        1
    )
    ON DUPLICATE KEY UPDATE
        avg_suhu = ((avg_suhu * data_count) + NEW.suhu) / (data_count + 1),
        min_suhu = LEAST(min_suhu, NEW.suhu),
        max_suhu = GREATEST(max_suhu, NEW.suhu),
        avg_kelembapan = ((avg_kelembapan * data_count) + NEW.kelembapan) / (data_count + 1),
        min_kelembapan = LEAST(min_kelembapan, NEW.kelembapan),
        max_kelembapan = GREATEST(max_kelembapan, NEW.kelembapan),
        data_count = data_count + 1;
    
    -- Update daily aggregation
    INSERT INTO sensor_data_daily (date_day, avg_suhu, min_suhu, max_suhu, 
                                   avg_kelembapan, min_kelembapan, max_kelembapan, data_count)
    VALUES (
        DATE(NEW.waktu),
        NEW.suhu,
        NEW.suhu,
        NEW.suhu,
        NEW.kelembapan,
        NEW.kelembapan,
        NEW.kelembapan,
        1
    )
    ON DUPLICATE KEY UPDATE
        avg_suhu = ((avg_suhu * data_count) + NEW.suhu) / (data_count + 1),
        min_suhu = LEAST(min_suhu, NEW.suhu),
        max_suhu = GREATEST(max_suhu, NEW.suhu),
        avg_kelembapan = ((avg_kelembapan * data_count) + NEW.kelembapan) / (data_count + 1),
        min_kelembapan = LEAST(min_kelembapan, NEW.kelembapan),
        max_kelembapan = GREATEST(max_kelembapan, NEW.kelembapan),
        data_count = data_count + 1;
END
$$
DELIMITER ;
DELIMITER $$
CREATE TRIGGER `trg_before_sensor_delete` BEFORE DELETE ON `sensor_data` FOR EACH ROW BEGIN
    INSERT INTO audit_logs (action_type, table_name, record_id, old_values)
    VALUES (
        'DELETE',
        'sensor_data',
        OLD.id,
        JSON_OBJECT(
            'suhu', OLD.suhu,
            'kelembapan', OLD.kelembapan,
            'waktu', OLD.waktu
        )
    );
END
$$
DELIMITER ;
DELIMITER $$
CREATE TRIGGER `trg_before_sensor_update` BEFORE UPDATE ON `sensor_data` FOR EACH ROW BEGIN
    INSERT INTO audit_logs (action_type, table_name, record_id, old_values, new_values)
    VALUES (
        'UPDATE',
        'sensor_data',
        OLD.id,
        JSON_OBJECT(
            'suhu', OLD.suhu,
            'kelembapan', OLD.kelembapan,
            'waktu', OLD.waktu
        ),
        JSON_OBJECT(
            'suhu', NEW.suhu,
            'kelembapan', NEW.kelembapan,
            'waktu', NEW.waktu
        )
    );
END
$$
DELIMITER ;

-- --------------------------------------------------------

--
-- Struktur dari tabel `sensor_data_daily`
--

CREATE TABLE `sensor_data_daily` (
  `daily_id` int NOT NULL,
  `date_day` date NOT NULL,
  `avg_suhu` decimal(5,2) NOT NULL,
  `min_suhu` decimal(5,2) NOT NULL,
  `max_suhu` decimal(5,2) NOT NULL,
  `avg_kelembapan` decimal(5,2) NOT NULL,
  `min_kelembapan` decimal(5,2) NOT NULL,
  `max_kelembapan` decimal(5,2) NOT NULL,
  `data_count` int NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data untuk tabel `sensor_data_daily`
--

INSERT INTO `sensor_data_daily` (`daily_id`, `date_day`, `avg_suhu`, `min_suhu`, `max_suhu`, `avg_kelembapan`, `min_kelembapan`, `max_kelembapan`, `data_count`) VALUES
(1, '2025-12-26', 25.50, 24.80, 26.50, 65.33, 60.00, 70.00, 6),
(2, '2025-12-25', 22.43, 21.80, 23.00, 75.17, 72.50, 78.00, 3),
(3, '2025-12-24', 24.75, 24.00, 25.50, 66.75, 65.00, 68.50, 2);

-- --------------------------------------------------------

--
-- Struktur dari tabel `sensor_data_hourly`
--

CREATE TABLE `sensor_data_hourly` (
  `hourly_id` int NOT NULL,
  `date_hour` datetime NOT NULL COMMENT 'Format: YYYY-MM-DD HH:00:00',
  `avg_suhu` decimal(5,2) NOT NULL,
  `min_suhu` decimal(5,2) NOT NULL,
  `max_suhu` decimal(5,2) NOT NULL,
  `avg_kelembapan` decimal(5,2) NOT NULL,
  `min_kelembapan` decimal(5,2) NOT NULL,
  `max_kelembapan` decimal(5,2) NOT NULL,
  `data_count` int NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data untuk tabel `sensor_data_hourly`
--

INSERT INTO `sensor_data_hourly` (`hourly_id`, `date_hour`, `avg_suhu`, `min_suhu`, `max_suhu`, `avg_kelembapan`, `min_kelembapan`, `max_kelembapan`, `data_count`) VALUES
(1, '2025-12-26 16:00:00', 25.60, 24.80, 26.50, 64.40, 60.00, 68.00, 5),
(2, '2025-12-25 17:00:00', 22.50, 22.50, 22.50, 75.00, 75.00, 75.00, 1);

-- --------------------------------------------------------

--
-- Struktur dari tabel `sensor_devices`
--

CREATE TABLE `sensor_devices` (
  `device_id` int NOT NULL,
  `device_name` varchar(100) COLLATE utf8mb4_unicode_ci NOT NULL COMMENT 'Nama perangkat sensor',
  `location` varchar(200) COLLATE utf8mb4_unicode_ci DEFAULT NULL COMMENT 'Lokasi pemasangan',
  `device_type` enum('TEMPERATURE','HUMIDITY','DUAL_SENSOR') COLLATE utf8mb4_unicode_ci DEFAULT 'DUAL_SENSOR',
  `status` enum('ACTIVE','INACTIVE','MAINTENANCE') COLLATE utf8mb4_unicode_ci DEFAULT 'ACTIVE',
  `installation_date` date DEFAULT NULL,
  `last_calibration` date DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data untuk tabel `sensor_devices`
--

INSERT INTO `sensor_devices` (`device_id`, `device_name`, `location`, `device_type`, `status`, `installation_date`, `last_calibration`) VALUES
(1, 'Sensor Greenhouse A1', 'Greenhouse A - Tengah', 'DUAL_SENSOR', 'MAINTENANCE', '2024-01-01', '2024-01-01'),
(2, 'Sensor Greenhouse A2', 'Greenhouse A - Utara', 'DUAL_SENSOR', 'MAINTENANCE', '2024-01-01', '2024-01-01'),
(3, 'Sensor Greenhouse B1', 'Greenhouse B - Selatan', 'DUAL_SENSOR', 'MAINTENANCE', '2024-01-15', '2024-01-15'),
(4, 'Sensor Kebun Utama', 'Kebun Sayur - Barat', 'DUAL_SENSOR', 'MAINTENANCE', '2024-01-10', '2024-01-10'),
(5, 'Sensor Nursery', 'Nursery - Dalam', 'DUAL_SENSOR', 'MAINTENANCE', '2024-01-05', '2024-01-05'),
(6, 'Sensor Hidroponik', 'Hidroponik - Atas', 'TEMPERATURE', 'MAINTENANCE', '2024-01-20', '2024-01-20');

--
-- Trigger `sensor_devices`
--
DELIMITER $$
CREATE TRIGGER `trg_before_device_update` BEFORE UPDATE ON `sensor_devices` FOR EACH ROW BEGIN
    -- If last_calibration is older than 6 months, set status to MAINTENANCE
    IF NEW.last_calibration < DATE_SUB(CURDATE(), INTERVAL 6 MONTH) THEN
        SET NEW.status = 'MAINTENANCE';
    END IF;
END
$$
DELIMITER ;

-- --------------------------------------------------------

--
-- Struktur dari tabel `sensor_thresholds`
--

CREATE TABLE `sensor_thresholds` (
  `threshold_id` int NOT NULL,
  `threshold_name` varchar(100) COLLATE utf8mb4_unicode_ci NOT NULL,
  `min_suhu` decimal(5,2) DEFAULT NULL COMMENT 'Minimum suhu normal',
  `max_suhu` decimal(5,2) DEFAULT NULL COMMENT 'Maksimum suhu normal',
  `min_kelembapan` decimal(5,2) DEFAULT NULL COMMENT 'Minimum kelembapan normal',
  `max_kelembapan` decimal(5,2) DEFAULT NULL COMMENT 'Maksimum kelembapan normal',
  `created_at` timestamp NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` timestamp NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data untuk tabel `sensor_thresholds`
--

INSERT INTO `sensor_thresholds` (`threshold_id`, `threshold_name`, `min_suhu`, `max_suhu`, `min_kelembapan`, `max_kelembapan`, `created_at`, `updated_at`) VALUES
(1, 'Tanaman Sayuran', 20.00, 30.00, 60.00, 80.00, '2025-12-26 10:05:41', '2025-12-26 10:05:41'),
(2, 'Tanaman Buah', 22.00, 32.00, 50.00, 70.00, '2025-12-26 10:05:41', '2025-12-26 10:05:41'),
(3, 'Tanaman Hidroponik', 18.00, 28.00, 65.00, 85.00, '2025-12-26 10:05:41', '2025-12-26 10:05:41'),
(4, 'Pembibitan', 25.00, 35.00, 70.00, 90.00, '2025-12-26 10:05:41', '2025-12-26 10:05:41');

-- --------------------------------------------------------

--
-- Struktur dari tabel `users`
--

CREATE TABLE `users` (
  `user_id` int NOT NULL,
  `username` varchar(50) COLLATE utf8mb4_unicode_ci NOT NULL,
  `password_hash` varchar(255) COLLATE utf8mb4_unicode_ci NOT NULL,
  `full_name` varchar(100) COLLATE utf8mb4_unicode_ci NOT NULL,
  `email` varchar(100) COLLATE utf8mb4_unicode_ci NOT NULL,
  `role` enum('ADMIN','OPERATOR','VIEWER') COLLATE utf8mb4_unicode_ci DEFAULT 'VIEWER',
  `is_active` tinyint(1) DEFAULT '1',
  `last_login` timestamp NULL DEFAULT NULL,
  `created_at` timestamp NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data untuk tabel `users`
--

INSERT INTO `users` (`user_id`, `username`, `password_hash`, `full_name`, `email`, `role`, `is_active`, `last_login`, `created_at`) VALUES
(1, 'admin', '$2y$10$YourHashedPasswordHere', 'Administrator Sistem', 'admin@smartfarming.com', 'ADMIN', 1, NULL, '2025-12-26 10:05:41'),
(2, 'operator1', '$2y$10$YourHashedPasswordHere', 'Operator Greenhouse', 'operator@smartfarming.com', 'OPERATOR', 1, NULL, '2025-12-26 10:05:41'),
(3, 'viewer1', '$2y$10$YourHashedPasswordHere', 'Viewer Only', 'viewer@smartfarming.com', 'VIEWER', 1, NULL, '2025-12-26 10:05:41');

-- --------------------------------------------------------

--
-- Stand-in struktur untuk tampilan `vw_active_alerts`
-- (Lihat di bawah untuk tampilan aktual)
--
CREATE TABLE `vw_active_alerts` (
`alert_id` int
,`alert_type` enum('TEMPERATURE_HIGH','TEMPERATURE_LOW','HUMIDITY_HIGH','HUMIDITY_LOW','DEVICE_OFFLINE')
,`alert_message` text
,`alert_level` enum('LOW','MEDIUM','HIGH','CRITICAL')
,`created_at` timestamp
,`suhu` decimal(5,2)
,`kelembapan` decimal(5,2)
,`reading_time` timestamp
,`days_open` int
);

-- --------------------------------------------------------

--
-- Stand-in struktur untuk tampilan `vw_daily_stats`
-- (Lihat di bawah untuk tampilan aktual)
--
CREATE TABLE `vw_daily_stats` (
`date_day` date
,`avg_suhu` decimal(5,2)
,`avg_kelembapan` decimal(5,2)
,`min_suhu` decimal(5,2)
,`max_suhu` decimal(5,2)
,`min_kelembapan` decimal(5,2)
,`max_kelembapan` decimal(5,2)
,`data_count` int
,`day_name` varchar(9)
);

-- --------------------------------------------------------

--
-- Stand-in struktur untuk tampilan `vw_dashboard_summary`
-- (Lihat di bawah untuk tampilan aktual)
--
CREATE TABLE `vw_dashboard_summary` (
`today_readings` bigint
,`total_readings` bigint
,`active_alerts` bigint
,`active_devices` bigint
,`avg_temp_today` decimal(6,2)
,`avg_humidity_today` decimal(6,2)
,`last_reading_time` timestamp
);

-- --------------------------------------------------------

--
-- Stand-in struktur untuk tampilan `vw_device_status`
-- (Lihat di bawah untuk tampilan aktual)
--
CREATE TABLE `vw_device_status` (
`device_id` int
,`device_name` varchar(100)
,`location` varchar(200)
,`device_type` enum('TEMPERATURE','HUMIDITY','DUAL_SENSOR')
,`status` enum('ACTIVE','INACTIVE','MAINTENANCE')
,`installation_date` date
,`last_calibration` date
,`zone_name` varchar(100)
,`crop_type` varchar(100)
,`days_since_calibration` int
,`operational_status` varchar(17)
,`readings_today` bigint
);

-- --------------------------------------------------------

--
-- Stand-in struktur untuk tampilan `vw_hourly_stats`
-- (Lihat di bawah untuk tampilan aktual)
--
CREATE TABLE `vw_hourly_stats` (
`date_hour` datetime
,`avg_suhu` decimal(5,2)
,`avg_kelembapan` decimal(5,2)
,`data_count` int
,`hour_label` varchar(7)
);

-- --------------------------------------------------------

--
-- Stand-in struktur untuk tampilan `vw_sensor_readings_detail`
-- (Lihat di bawah untuk tampilan aktual)
--
CREATE TABLE `vw_sensor_readings_detail` (
`id` int
,`suhu` decimal(5,2)
,`kelembapan` decimal(5,2)
,`waktu` timestamp
,`device_name` varchar(100)
,`location` varchar(200)
,`device_type` enum('TEMPERATURE','HUMIDITY','DUAL_SENSOR')
,`device_status` enum('ACTIVE','INACTIVE','MAINTENANCE')
,`zone_name` varchar(100)
,`crop_type` varchar(100)
,`temperature_status` varchar(7)
,`humidity_status` varchar(6)
);

-- --------------------------------------------------------

--
-- Struktur dari tabel `zone_sensors`
--

CREATE TABLE `zone_sensors` (
  `zone_id` int NOT NULL,
  `device_id` int NOT NULL,
  `installation_date` date DEFAULT NULL,
  `height` decimal(5,2) DEFAULT NULL COMMENT 'Tinggi pemasangan (meter)'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data untuk tabel `zone_sensors`
--

INSERT INTO `zone_sensors` (`zone_id`, `device_id`, `installation_date`, `height`) VALUES
(1, 1, '2024-01-01', 1.50),
(1, 2, '2024-01-01', 1.80),
(2, 3, '2024-01-15', 1.60),
(3, 4, '2024-01-10', 0.80),
(4, 5, '2024-01-05', 1.20),
(5, 6, '2024-01-20', 1.00);

--
-- Indexes for dumped tables
--

--
-- Indeks untuk tabel `api_tokens`
--
ALTER TABLE `api_tokens`
  ADD PRIMARY KEY (`token_id`),
  ADD UNIQUE KEY `token` (`token`),
  ADD KEY `idx_token` (`token`),
  ADD KEY `idx_expires_at` (`expires_at`),
  ADD KEY `user_id` (`user_id`);

--
-- Indeks untuk tabel `audit_logs`
--
ALTER TABLE `audit_logs`
  ADD PRIMARY KEY (`log_id`),
  ADD KEY `idx_action_type` (`action_type`),
  ADD KEY `idx_created_at` (`created_at` DESC),
  ADD KEY `idx_user_id` (`user_id`);

--
-- Indeks untuk tabel `farming_zones`
--
ALTER TABLE `farming_zones`
  ADD PRIMARY KEY (`zone_id`),
  ADD KEY `idx_zone_type` (`zone_type`);

--
-- Indeks untuk tabel `sensor_alerts`
--
ALTER TABLE `sensor_alerts`
  ADD PRIMARY KEY (`alert_id`),
  ADD KEY `idx_alert_type` (`alert_type`),
  ADD KEY `idx_is_resolved` (`is_resolved`),
  ADD KEY `idx_created_at` (`created_at` DESC),
  ADD KEY `sensor_id` (`sensor_id`),
  ADD KEY `idx_sensor_alerts_composite` (`is_resolved`,`alert_level`,`created_at` DESC);

--
-- Indeks untuk tabel `sensor_data`
--
ALTER TABLE `sensor_data`
  ADD PRIMARY KEY (`id`),
  ADD KEY `idx_waktu` (`waktu` DESC),
  ADD KEY `idx_suhu` (`suhu`),
  ADD KEY `idx_kelembapan` (`kelembapan`),
  ADD KEY `idx_sensor_data_composite` (`waktu` DESC,`suhu`,`kelembapan`);

--
-- Indeks untuk tabel `sensor_data_daily`
--
ALTER TABLE `sensor_data_daily`
  ADD PRIMARY KEY (`daily_id`),
  ADD UNIQUE KEY `idx_date_day` (`date_day`),
  ADD KEY `idx_date` (`date_day` DESC);

--
-- Indeks untuk tabel `sensor_data_hourly`
--
ALTER TABLE `sensor_data_hourly`
  ADD PRIMARY KEY (`hourly_id`),
  ADD UNIQUE KEY `idx_date_hour` (`date_hour`),
  ADD KEY `idx_date` (`date_hour`);

--
-- Indeks untuk tabel `sensor_devices`
--
ALTER TABLE `sensor_devices`
  ADD PRIMARY KEY (`device_id`),
  ADD KEY `idx_status` (`status`),
  ADD KEY `idx_location` (`location`);

--
-- Indeks untuk tabel `sensor_thresholds`
--
ALTER TABLE `sensor_thresholds`
  ADD PRIMARY KEY (`threshold_id`);

--
-- Indeks untuk tabel `users`
--
ALTER TABLE `users`
  ADD PRIMARY KEY (`user_id`),
  ADD UNIQUE KEY `username` (`username`),
  ADD UNIQUE KEY `email` (`email`),
  ADD KEY `idx_username` (`username`),
  ADD KEY `idx_email` (`email`),
  ADD KEY `idx_role` (`role`);

--
-- Indeks untuk tabel `zone_sensors`
--
ALTER TABLE `zone_sensors`
  ADD PRIMARY KEY (`zone_id`,`device_id`),
  ADD KEY `device_id` (`device_id`);

--
-- AUTO_INCREMENT untuk tabel yang dibuang
--

--
-- AUTO_INCREMENT untuk tabel `api_tokens`
--
ALTER TABLE `api_tokens`
  MODIFY `token_id` int NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT untuk tabel `audit_logs`
--
ALTER TABLE `audit_logs`
  MODIFY `log_id` int NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=3;

--
-- AUTO_INCREMENT untuk tabel `farming_zones`
--
ALTER TABLE `farming_zones`
  MODIFY `zone_id` int NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=6;

--
-- AUTO_INCREMENT untuk tabel `sensor_alerts`
--
ALTER TABLE `sensor_alerts`
  MODIFY `alert_id` int NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT untuk tabel `sensor_data`
--
ALTER TABLE `sensor_data`
  MODIFY `id` int NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT untuk tabel `sensor_data_daily`
--
ALTER TABLE `sensor_data_daily`
  MODIFY `daily_id` int NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=4;

--
-- AUTO_INCREMENT untuk tabel `sensor_data_hourly`
--
ALTER TABLE `sensor_data_hourly`
  MODIFY `hourly_id` int NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=5;

--
-- AUTO_INCREMENT untuk tabel `sensor_devices`
--
ALTER TABLE `sensor_devices`
  MODIFY `device_id` int NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=7;

--
-- AUTO_INCREMENT untuk tabel `sensor_thresholds`
--
ALTER TABLE `sensor_thresholds`
  MODIFY `threshold_id` int NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=5;

--
-- AUTO_INCREMENT untuk tabel `users`
--
ALTER TABLE `users`
  MODIFY `user_id` int NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=4;

-- --------------------------------------------------------

--
-- Struktur untuk view `vw_active_alerts`
--
DROP TABLE IF EXISTS `vw_active_alerts`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_active_alerts`  AS SELECT `a`.`alert_id` AS `alert_id`, `a`.`alert_type` AS `alert_type`, `a`.`alert_message` AS `alert_message`, `a`.`alert_level` AS `alert_level`, `a`.`created_at` AS `created_at`, `sd`.`suhu` AS `suhu`, `sd`.`kelembapan` AS `kelembapan`, `sd`.`waktu` AS `reading_time`, (to_days(now()) - to_days(`a`.`created_at`)) AS `days_open` FROM (`sensor_alerts` `a` left join `sensor_data` `sd` on((`a`.`sensor_id` = `sd`.`id`))) WHERE (`a`.`is_resolved` = false) ORDER BY (case `a`.`alert_level` when 'CRITICAL' then 1 when 'HIGH' then 2 when 'MEDIUM' then 3 when 'LOW' then 4 end) ASC, `a`.`created_at` DESC ;

-- --------------------------------------------------------

--
-- Struktur untuk view `vw_daily_stats`
--
DROP TABLE IF EXISTS `vw_daily_stats`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_daily_stats`  AS SELECT `sensor_data_daily`.`date_day` AS `date_day`, `sensor_data_daily`.`avg_suhu` AS `avg_suhu`, `sensor_data_daily`.`avg_kelembapan` AS `avg_kelembapan`, `sensor_data_daily`.`min_suhu` AS `min_suhu`, `sensor_data_daily`.`max_suhu` AS `max_suhu`, `sensor_data_daily`.`min_kelembapan` AS `min_kelembapan`, `sensor_data_daily`.`max_kelembapan` AS `max_kelembapan`, `sensor_data_daily`.`data_count` AS `data_count`, dayname(`sensor_data_daily`.`date_day`) AS `day_name` FROM `sensor_data_daily` WHERE (`sensor_data_daily`.`date_day` >= (curdate() - interval 7 day)) ORDER BY `sensor_data_daily`.`date_day` DESC ;

-- --------------------------------------------------------

--
-- Struktur untuk view `vw_dashboard_summary`
--
DROP TABLE IF EXISTS `vw_dashboard_summary`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_dashboard_summary`  AS SELECT (select count(0) from `sensor_data` where (cast(`sensor_data`.`waktu` as date) = curdate())) AS `today_readings`, (select count(0) from `sensor_data`) AS `total_readings`, (select count(0) from `sensor_alerts` where (`sensor_alerts`.`is_resolved` = false)) AS `active_alerts`, (select count(0) from `sensor_devices` where (`sensor_devices`.`status` = 'ACTIVE')) AS `active_devices`, (select round(avg(`sensor_data`.`suhu`),2) from `sensor_data` where (cast(`sensor_data`.`waktu` as date) = curdate())) AS `avg_temp_today`, (select round(avg(`sensor_data`.`kelembapan`),2) from `sensor_data` where (cast(`sensor_data`.`waktu` as date) = curdate())) AS `avg_humidity_today`, (select max(`sensor_data`.`waktu`) from `sensor_data`) AS `last_reading_time` ;

-- --------------------------------------------------------

--
-- Struktur untuk view `vw_device_status`
--
DROP TABLE IF EXISTS `vw_device_status`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_device_status`  AS SELECT `d`.`device_id` AS `device_id`, `d`.`device_name` AS `device_name`, `d`.`location` AS `location`, `d`.`device_type` AS `device_type`, `d`.`status` AS `status`, `d`.`installation_date` AS `installation_date`, `d`.`last_calibration` AS `last_calibration`, `z`.`zone_name` AS `zone_name`, `z`.`crop_type` AS `crop_type`, (to_days(curdate()) - to_days(`d`.`last_calibration`)) AS `days_since_calibration`, (case when ((to_days(curdate()) - to_days(`d`.`last_calibration`)) > 180) then 'NEEDS_CALIBRATION' when (`d`.`status` = 'MAINTENANCE') then 'UNDER_MAINTENANCE' when (`d`.`status` = 'INACTIVE') then 'INACTIVE' else 'OPERATIONAL' end) AS `operational_status`, (select count(0) from `sensor_data` `sd` where ((cast(`sd`.`waktu` as date) = curdate()) and exists(select 1 from `zone_sensors` `zs` where (`zs`.`device_id` = `d`.`device_id`)))) AS `readings_today` FROM ((`sensor_devices` `d` left join `zone_sensors` `zs` on((`d`.`device_id` = `zs`.`device_id`))) left join `farming_zones` `z` on((`zs`.`zone_id` = `z`.`zone_id`))) ;

-- --------------------------------------------------------

--
-- Struktur untuk view `vw_hourly_stats`
--
DROP TABLE IF EXISTS `vw_hourly_stats`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_hourly_stats`  AS SELECT `sensor_data_hourly`.`date_hour` AS `date_hour`, `sensor_data_hourly`.`avg_suhu` AS `avg_suhu`, `sensor_data_hourly`.`avg_kelembapan` AS `avg_kelembapan`, `sensor_data_hourly`.`data_count` AS `data_count`, concat(hour(`sensor_data_hourly`.`date_hour`),':00') AS `hour_label` FROM `sensor_data_hourly` WHERE (`sensor_data_hourly`.`date_hour` >= (curdate() - interval 24 hour)) ORDER BY `sensor_data_hourly`.`date_hour` ASC ;

-- --------------------------------------------------------

--
-- Struktur untuk view `vw_sensor_readings_detail`
--
DROP TABLE IF EXISTS `vw_sensor_readings_detail`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_sensor_readings_detail`  AS SELECT `sd`.`id` AS `id`, `sd`.`suhu` AS `suhu`, `sd`.`kelembapan` AS `kelembapan`, `sd`.`waktu` AS `waktu`, `d`.`device_name` AS `device_name`, `d`.`location` AS `location`, `d`.`device_type` AS `device_type`, `d`.`status` AS `device_status`, `z`.`zone_name` AS `zone_name`, `z`.`crop_type` AS `crop_type`, (case when (`sd`.`suhu` < 20) then 'Dingin' when (`sd`.`suhu` between 20 and 30) then 'Optimal' when (`sd`.`suhu` > 30) then 'Panas' end) AS `temperature_status`, (case when (`sd`.`kelembapan` < 60) then 'Kering' when (`sd`.`kelembapan` between 60 and 80) then 'Ideal' when (`sd`.`kelembapan` > 80) then 'Lembab' end) AS `humidity_status` FROM (((`sensor_data` `sd` left join `zone_sensors` `zs` on((1 = 1))) left join `sensor_devices` `d` on((`zs`.`device_id` = `d`.`device_id`))) left join `farming_zones` `z` on((`zs`.`zone_id` = `z`.`zone_id`))) ORDER BY `sd`.`waktu` DESC ;

--
-- Ketidakleluasaan untuk tabel pelimpahan (Dumped Tables)
--

--
-- Ketidakleluasaan untuk tabel `api_tokens`
--
ALTER TABLE `api_tokens`
  ADD CONSTRAINT `api_tokens_ibfk_1` FOREIGN KEY (`user_id`) REFERENCES `users` (`user_id`) ON DELETE CASCADE;

--
-- Ketidakleluasaan untuk tabel `audit_logs`
--
ALTER TABLE `audit_logs`
  ADD CONSTRAINT `audit_logs_ibfk_1` FOREIGN KEY (`user_id`) REFERENCES `users` (`user_id`) ON DELETE SET NULL;

--
-- Ketidakleluasaan untuk tabel `sensor_alerts`
--
ALTER TABLE `sensor_alerts`
  ADD CONSTRAINT `sensor_alerts_ibfk_1` FOREIGN KEY (`sensor_id`) REFERENCES `sensor_data` (`id`) ON DELETE SET NULL;

--
-- Ketidakleluasaan untuk tabel `zone_sensors`
--
ALTER TABLE `zone_sensors`
  ADD CONSTRAINT `zone_sensors_ibfk_1` FOREIGN KEY (`zone_id`) REFERENCES `farming_zones` (`zone_id`) ON DELETE CASCADE,
  ADD CONSTRAINT `zone_sensors_ibfk_2` FOREIGN KEY (`device_id`) REFERENCES `sensor_devices` (`device_id`) ON DELETE CASCADE;

DELIMITER $$
--
-- Event
--
CREATE DEFINER=`root`@`localhost` EVENT `evt_daily_cleanup` ON SCHEDULE EVERY 1 DAY STARTS '2025-12-26 17:08:15' ON COMPLETION NOT PRESERVE ENABLE DO BEGIN
    CALL sp_clean_old_data(90);
END$$

CREATE DEFINER=`root`@`localhost` EVENT `evt_hourly_aggregation` ON SCHEDULE EVERY 1 HOUR STARTS '2025-12-26 17:08:15' ON COMPLETION NOT PRESERVE ENABLE DO BEGIN
    CALL sp_generate_hourly_aggregation();
END$$

CREATE DEFINER=`root`@`localhost` EVENT `evt_check_calibration` ON SCHEDULE EVERY 1 DAY STARTS '2025-12-26 17:08:15' ON COMPLETION NOT PRESERVE ENABLE DO BEGIN
    UPDATE sensor_devices 
    SET status = 'MAINTENANCE'
    WHERE last_calibration < DATE_SUB(CURDATE(), INTERVAL 6 MONTH)
      AND status = 'ACTIVE';
    
    -- Log the action
    INSERT INTO audit_logs (action_type, table_name, new_values)
    VALUES ('CALIBRATION_CHECK', 'sensor_devices', 
            JSON_OBJECT('checked_at', NOW(), 'devices_updated', ROW_COUNT()));
END$$

CREATE DEFINER=`root`@`localhost` EVENT `evt_resolve_old_alerts` ON SCHEDULE EVERY 1 DAY STARTS '2025-12-26 17:08:15' ON COMPLETION NOT PRESERVE ENABLE DO BEGIN
    UPDATE sensor_alerts 
    SET is_resolved = TRUE, 
        resolved_at = NOW()
    WHERE is_resolved = FALSE 
      AND created_at < DATE_SUB(NOW(), INTERVAL 7 DAY);
END$$

DELIMITER ;
COMMIT;

/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
