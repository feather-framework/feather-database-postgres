//
//  DatabaseConnectionPostgres.swift
//  feather-database-postgres
//
//  Created by Tibor Bödecs on 2026. 01. 10.
//

import FeatherDatabase
import Logging
import PostgresNIO

extension DatabaseQuery {

    fileprivate func toPostgresQuery() -> PostgresQuery {
        var postgresUnsafeSQL = sql
        var postgresBindings: PostgresBindings = .init()

        for binding in bindings {
            /// postgres binding index starts with 1
            let idx = binding.index + 1
            postgresUnsafeSQL =
                postgresUnsafeSQL
                .replacing("{{\(idx)}}", with: "$\(idx)")

            switch binding.binding {
            case .bool(let value):
                postgresBindings.append(value)
            case .int(let value):
                postgresBindings.append(value)
            case .double(let value):
                postgresBindings.append(value)
            case .string(let value):
                postgresBindings.append(value)
            }
        }

        return .init(
            unsafeSQL: postgresUnsafeSQL,
            binds: postgresBindings
        )
    }
}

public struct DatabaseConnectionPostgres: DatabaseConnection {

    public typealias RowSequence = DatabaseRowSequencePostgres

    var connection: PostgresConnection

    /// Execute a Postgres query on this connection.
    ///
    /// This wraps `PostgresNIO` query execution and maps errors.
    /// - Parameters:
    ///   - query: The Postgres query to execute.
    ///   - handler: A closure that receives the RowSequence result.
    /// - Throws: A `DatabaseError` if the query fails.
    /// - Returns: A query result containing the returned rows.
    @discardableResult
    public func run<T: Sendable>(
        query: DatabaseQuery,
        _ handler: (RowSequence) async throws -> T = { $0 }
    ) async throws(DatabaseError) -> T {
        do {
            let sequence = try await connection.query(
                query.toPostgresQuery(),
                logger: Logger.current
            )

            return try await handler(
                DatabaseRowSequencePostgres(
                    backingSequence: sequence
                )
            )
        }
        catch {
            throw .query(error)
        }
    }
}
