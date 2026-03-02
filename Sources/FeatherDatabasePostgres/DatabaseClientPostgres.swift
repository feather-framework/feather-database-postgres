//
//  DatabaseClientPostgres.swift
//  feather-database-postgres
//
//  Created by Tibor Bödecs on 2026. 01. 10..
//

import FeatherDatabase
import Logging
import PostgresNIO

/// A Postgres-backed database client.
///
/// Use this client to execute queries and manage transactions on Postgres.
public struct DatabaseClientPostgres: DatabaseClient {
    public typealias Connection = DatabaseConnectionPostgres

    var client: PostgresNIO.PostgresClient
    let logger: Logger

    /// Create a Postgres database client.
    ///
    /// Use this initializer to provide an existing Postgres client.
    /// - Parameters:
    ///   - client: The underlying Postgres client.
    ///   - logger: The logger for database operations.
    public init(
        client: PostgresNIO.PostgresClient,
        logger: Logger
    ) {
        self.client = client
        self.logger = logger
    }

    // MARK: - database api

    /// Execute work using a managed Postgres connection.
    ///
    /// The closure receives a Postgres connection for the duration of the call.
    /// - Parameter: closure: A closure that receives the connection.
    /// - Throws: A `DatabaseError` if connection handling fails.
    /// - Returns: The query result produced by the closure.
    @discardableResult
    public func withConnection<T>(
        _ closure: (Connection) async throws -> T,
    ) async throws(DatabaseError) -> T {
        let logger = self.logger
        let body: (PostgresConnection) async throws -> T = { connection in
            try await closure(
                DatabaseConnectionPostgres(
                    connection: connection,
                    logger: logger
                )
            )
        }

        do {
            return try await client.withConnection(body)
        }
        catch let error as DatabaseError {
            throw error
        }
        catch {
            throw .connection(error)
        }
    }

    /// Execute work inside a Postgres transaction.
    ///
    /// The closure is wrapped in a transactional scope.
    /// - Parameter: closure: A closure that receives the connection.
    /// - Throws: A `DatabaseError` if the transaction fails.
    /// - Returns: The query result produced by the closure.
    @discardableResult
    public func withTransaction<T>(
        _ closure: (Connection) async throws -> T,
    ) async throws(DatabaseError) -> T {
        let logger = self.logger
        let beginQuery = PostgresQuery(unsafeSQL: "BEGIN", binds: .init())
        let commitQuery = PostgresQuery(unsafeSQL: "COMMIT", binds: .init())
        let rollbackQuery = PostgresQuery(unsafeSQL: "ROLLBACK", binds: .init())

        do {
            return try await client.withConnection { connection in
                let databaseConnection = DatabaseConnectionPostgres(
                    connection: connection,
                    logger: logger
                )

                do {
                    _ = try await connection.query(beginQuery, logger: logger)
                }
                catch {
                    throw DatabaseError.transaction(
                        DatabaseTransactionErrorPostgres(
                            beginError: error
                        )
                    )
                }

                do {
                    let result = try await closure(databaseConnection)
                    do {
                        _ = try await connection.query(
                            commitQuery,
                            logger: logger
                        )
                        return result
                    }
                    catch {
                        let commitError = error
                        var rollbackError: (any Error)?
                        do {
                            _ = try await connection.query(
                                rollbackQuery,
                                logger: logger
                            )
                        }
                        catch {
                            rollbackError = error
                        }
                        throw DatabaseError.transaction(
                            DatabaseTransactionErrorPostgres(
                                commitError: commitError,
                                rollbackError: rollbackError
                            )
                        )
                    }
                }
                catch {
                    let closureError = error
                    var rollbackError: (any Error)?
                    do {
                        _ = try await connection.query(
                            rollbackQuery,
                            logger: logger
                        )
                    }
                    catch {
                        rollbackError = error
                    }
                    throw DatabaseError.transaction(
                        DatabaseTransactionErrorPostgres(
                            closureError: closureError,
                            rollbackError: rollbackError
                        )
                    )
                }
            }
        }
        catch let error as DatabaseError {
            throw error
        }
        catch {
            throw .connection(error)
        }
    }

}
