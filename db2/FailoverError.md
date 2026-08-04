## All pod are running perfectly

### Primary working fine
![Primary Hadr](../images/primaryHadr.png)
### Standby working fine
![Standby Hadr](../images/standbyHadr.png)

### After Switchover
![After Switchover](../images/afterSwitchOver.png)

### Trying to failover
After that I have deleted primary pod. and tried to failover in standby by force

***After Deleting the primary pod hadr config in standby Pod***
![After Deleting the primary pod hadr config in standby Pod](../images/afterDeletiengPrimaryPod.png)

Now I am trying to failover in standby by force<br>
***command:***
bash
db2 takeover HADR ON DATABASE $db_name by force


Error I got:
![Failover Error](../images/failoverError.png)

An incomplete failover happened. HADR is not not. A database connection cannot be established. and no command is successful on the new primary.

here is the new primary configuration:
![New Primary Config](../images/configureIncompleteFailover.png)