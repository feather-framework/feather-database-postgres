//
//  DatabaseRowSequencePostgres.swift
//  feather-database-postgres
//
//  Created by Tibor Bödecs on 2026. 01. 10.
//

import FeatherDatabase
import PostgresNIO

/// A query result backed by a Postgres row sequence.
///
/// Use this type to iterate or collect Postgres query results.
public struct DatabaseRowSequencePostgres: DatabaseRowSequence {
    public typealias Row = DatabaseRowPostgres

    var backingSequence: PostgresRowSequence

    /// An async iterator over Postgres rows.
    ///
    /// This iterator pulls rows from the backing sequence.
    public struct AsyncIterator: AsyncIteratorProtocol {
        var backingIterator: PostgresRowSequence.AsyncIterator

        /// Return the next row in the sequence.
        ///
        /// This stops when the sequence ends or the task is cancelled.
        /// - Throws: An error if the underlying sequence fails.
        /// - Returns: The next `PostgresRow`, or `nil` when finished.
        #if compiler(>=6.2)
        @concurrent
        public mutating func next() async throws -> DatabaseRowPostgres? {
            guard !Task.isCancelled else {
                return nil
            }
            guard let postgresRow = try await backingIterator.next() else {
                return nil
            }
            return .init(row: postgresRow)
        }
        #else
        public mutating func next() async throws -> DatabaseRowPostgres? {
            guard !Task.isCancelled else {
                return nil
            }
            guard let postgresRow = try await backingIterator.next() else {
                return nil
            }
            return .init(row: postgresRow)
        }
        #endif
    }

    /// Create an async iterator over the result rows.
    ///
    /// Use this to iterate the result as an `AsyncSequence`.
    /// - Returns: An iterator over the result rows.
    public func makeAsyncIterator() -> AsyncIterator {
        .init(
            backingIterator: backingSequence.makeAsyncIterator(),
        )
    }

    /// Collect all rows into an array.
    ///
    /// This consumes the sequence and returns all rows.
    /// - Throws: An error if iteration fails.
    /// - Returns: An array of `PostgresRow` values.
    public func collect() async throws -> [DatabaseRowPostgres] {
        var items: [DatabaseRowPostgres] = []
        for try await item in self {
            items.append(item)
        }
        return items
    }
}
