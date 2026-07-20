# zlock

[zlock](https://github.com/rito1998/zlock) is a simple network-based mutex. Using TCP connections to a server, clients can create, acquire, and release locks, enabling synchronization between applications that cannot otherwise safely access a shared resource.

## Usage

Launch a **zlock server** instance. In the examples below, the server listens on port `1998`:

```pwsh
./zlock.exe server --address [::1]:1998
```

Clients can interact with the server either through a simple TCP connection—for example, using **ncat** as shown below—or through the zlock CLI client.

The server API is intentionally bare-bones. It expects incoming TCP connections with messages following this format:

```text
<command> <lock-name> <parameters>
```

### ncat (CLI)

The following commands are available:

* **create** — creates a lock on the server using the specified name:

  ```pwsh
  "create ExampleLockName" | ncat localhost 1998
  ```

  The server replies with `created` or `already_exists`.

* **lock** — blocks until the specified lock can be acquired. The second parameter specifies the lease time in milliseconds. The lease ensures that the lock is eventually released if the client forgets to unlock it or crashes:

  ```pwsh
  "lock ExampleLockName 10000" | ncat localhost 1998
  ```

  The server replies with `granted`.

* **trylock** — attempts to acquire the specified lock without blocking. It accepts the same parameters as `lock`:

  ```pwsh
  "trylock ExampleLockName 10000" | ncat localhost 1998
  ```

  The server replies with `granted`, `denied`, or `not_found`.

* **unlock** — releases the specified lock:

  ```pwsh
  "unlock ExampleLockName" | ncat localhost 1998
  ```

  The server replies with `unlocked` or `not_found`.

* **version** — returns the server version as a SemVer string:

  ```pwsh
  "version" | ncat localhost 1998
  ```

  For example: `0.1.0`.

* **help** — displays the server help menu:

  ```pwsh
  "help" | ncat localhost 1998
  ```

### zlock client (CLI)

The zlock CLI client is currently a TODO. It will follow the same pattern as the raw TCP/ncat interface shown above.

```pwsh
./zlock.exe trylock lock_name_here 10000 --server [::1]:1998
```

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.
