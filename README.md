# fml
A convenience interface for managing multiple local MongoDB instances. Uses aliases and a configuration file to manage instances. 

Example ~/fml/fml_config.json:
```
{
  "test7": {
    "directory": "mlaunchdata/test7",
    "startPort": 27000,
    "mongoVersion": "7.0.9",
    "initArgs": "--replicaset",
    "connectionString": "mongodb://localhost:27000,localhost:27001,localhost:27002",
    "comment": "this is a comment"
  }
}
```
