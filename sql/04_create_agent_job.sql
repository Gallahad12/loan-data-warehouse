-- SQL Server Agent job that runs Master.dtsx from the SSIS catalog every day at 02:00.
-- Run after the project is deployed to /SSISDB/LoanDW/LoanDW_ETL. Safe to re-run.
USE msdb;
GO

DECLARE @job_name sysname = N'LoanDW - Daily ETL';

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @job_name)
    EXEC msdb.dbo.sp_delete_job @job_name = @job_name, @delete_unused_schedule = 1;

EXEC msdb.dbo.sp_add_job
    @job_name = @job_name,
    @description = N'Runs the LoanDW ETL: stage LoanCore and payment files, load dimensions and facts, rebuild the monthly snapshot.',
    @enabled = 1;

-- SYNCHRONIZED=True makes the step wait for the package and fail when the package fails.
EXEC msdb.dbo.sp_add_jobstep
    @job_name = @job_name,
    @step_name = N'Run Master.dtsx',
    @subsystem = N'SSIS',
    @command = N'/ISSERVER "\"\SSISDB\LoanDW\LoanDW_ETL\Master.dtsx\"" /SERVER "\"localhost\"" /Par "\"$ServerOption::LOGGING_LEVEL(Int16)\"";1 /Par "\"$ServerOption::SYNCHRONIZED(Boolean)\"";True /CALLERINFO SQLAGENT /REPORTING E',
    @retry_attempts = 1,
    @retry_interval = 5;

EXEC msdb.dbo.sp_add_jobschedule
    @job_name = @job_name,
    @name = N'Daily 02:00',
    @freq_type = 4,              -- daily
    @freq_interval = 1,          -- every day
    @active_start_time = 20000;  -- 02:00:00

EXEC msdb.dbo.sp_add_jobserver @job_name = @job_name, @server_name = N'(local)';
GO
