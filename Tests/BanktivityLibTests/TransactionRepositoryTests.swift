// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
import Testing
@testable import BanktivityLib

// Runs on the main actor: see TestVaultHelper for why every suite that
// touches a view context has to.
@Suite("TransactionRepository", .serialized)
@MainActor
struct TransactionRepositoryTests {

    private func makeRepositories() throws -> (
        vault: TestVaultHelper.TestVault,
        accounts: AccountRepository,
        transactions: TransactionRepository
    ) {
        let vault = try TestVaultHelper.createFreshVault()
        _ = try TestVaultHelper.seedCurrencies(in: vault.container)
        _ = try TestVaultHelper.seedTransactionTypes(in: vault.container)

        let accounts = AccountRepository(container: vault.container)
        let lineItems = LineItemRepository(container: vault.container)
        let transactions = TransactionRepository(container: vault.container, lineItemRepo: lineItems)

        return (vault, accounts, transactions)
    }

    /// Seeds Return Of Capital first so an unsorted `fetchLimit = 1` would pick
    /// it — the original create() bug — then the cash types we actually want.
    private func makeRepositoriesWithCashTypes() throws -> (
        vault: TestVaultHelper.TestVault,
        accounts: AccountRepository,
        categories: CategoryRepository,
        transactions: TransactionRepository
    ) {
        let vault = try TestVaultHelper.createFreshVault()
        _ = try TestVaultHelper.seedCurrencies(in: vault.container)
        try seedTransactionType(in: vault.container, baseType: 310, name: "Return Of Capital")
        try seedTransactionType(in: vault.container, baseType: 1, name: "Deposit")
        try seedTransactionType(in: vault.container, baseType: 2, name: "Withdrawal")
        try seedTransactionType(in: vault.container, baseType: 3, name: "Transfer")
        _ = try TestVaultHelper.seedTransactionTypes(in: vault.container)

        let accounts = AccountRepository(container: vault.container)
        let categories = CategoryRepository(container: vault.container)
        let lineItems = LineItemRepository(container: vault.container)
        let transactions = TransactionRepository(container: vault.container, lineItemRepo: lineItems)

        return (vault, accounts, categories, transactions)
    }

    private func seedTransactionType(in container: NSPersistentContainer, baseType: Int16, name: String) throws {
        let ctx = container.viewContext
        let type = NSEntityDescription.insertNewObject(forEntityName: "TransactionType", into: ctx)
        type.setValue(baseType, forKey: "pBaseType")
        type.setValue(name, forKey: "pName")
        type.setValue(UUID().uuidString, forKey: "pUniqueID")
        type.setValue(Date(), forKey: "pCreationTime")
        type.setValue(Date(), forKey: "pModificationDate")
        try ctx.save()
    }

    @Test("Create returns the newly inserted transaction, not a title-search match")
    func createReturnsInsertedTransactionWhenLaterMatchingTitleExists() throws {
        let repos = try makeRepositories()
        defer { TestVaultHelper.cleanup(repos.vault) }

        let account = try repos.accounts.create(
            name: "Synthetic Checking",
            accountClass: AccountClass.checking,
            currencyCode: "USD"
        )

        let existing = try repos.transactions.create(
            date: "2026-05-10",
            title: "Later Vendor Alpha Payment",
            lineItems: [(accountId: account.id, amount: -10.0, memo: nil)]
        )

        let created = try repos.transactions.create(
            date: "2026-04-09",
            title: "Vendor Alpha",
            lineItems: [(accountId: account.id, amount: -20.0, memo: nil)]
        )

        #expect(created.id != existing.id)
        #expect(created.title == "Vendor Alpha")
        #expect(created.date == "2026-04-09")
        #expect(created.lineItems.contains { $0.accountId == account.id && abs($0.amount - -20.0) < 0.005 })
    }

    @Test("List rejects missing account filter instead of returning the whole vault")
    func listRejectsMissingAccountFilter() throws {
        let repos = try makeRepositories()
        defer { TestVaultHelper.cleanup(repos.vault) }

        let account = try repos.accounts.create(
            name: "Filtered Checking",
            accountClass: AccountClass.checking,
            currencyCode: "USD"
        )
        _ = try repos.transactions.create(
            date: "2026-05-10",
            title: "Should not leak through missing account filter",
            lineItems: [(accountId: account.id, amount: -10.0, memo: nil)]
        )

        do {
            _ = try repos.transactions.list(accountId: 999_999)
            Issue.record("Expected missing account filter to fail")
        } catch let error as ToolError {
            if case .notFound(let message) = error {
                #expect(message == "Account not found: 999999")
            } else {
                Issue.record("Expected notFound, got \(error)")
            }
        } catch {
            Issue.record("Expected ToolError.notFound, got \(error)")
        }

        let filtered = try repos.transactions.list(accountId: account.id)
        #expect(filtered.count == 1)
        #expect(filtered.first?.title == "Should not leak through missing account filter")
    }

    // Added 2026-09-02. Midnight is the START of a day, so an end bound built as
    // `pDate <= midnight(endDate)` drops every row stored later in that day.
    // Measured on the production vault before any anchoring work: two of three
    // sampled rows were already missing from a same-day window. Anchored writes
    // land at 10:00 UTC and would be dropped every time.
    @Test("a same-day window returns a row written that day")
    func sameDayWindowReturnsTheRowWrittenThatDay() throws {
        let repos = try makeRepositories()
        defer { TestVaultHelper.cleanup(repos.vault) }

        let account = try repos.accounts.create(
            name: "Synthetic Checking",
            accountClass: AccountClass.checking,
            currencyCode: "USD"
        )

        let created = try repos.transactions.create(
            date: "2026-06-08",
            title: "Same day window probe",
            lineItems: [(accountId: account.id, amount: -12.34, memo: nil)]
        )
        #expect(created.date == "2026-06-08")

        let sameDay = try repos.transactions.list(
            accountId: account.id, startDate: "2026-06-08", endDate: "2026-06-08"
        )
        #expect(sameDay.contains { $0.id == created.id })

        // The bound must be exclusive of the NEXT day, not inclusive of this one:
        // a window ending the day before must still not return it.
        let dayBefore = try repos.transactions.list(
            accountId: account.id, startDate: "2026-06-01", endDate: "2026-06-07"
        )
        #expect(!dayBefore.contains { $0.id == created.id })
    }

    @Test("Create with explicit transaction_type sets Deposit instead of the first vault type")
    func createWithExplicitDepositSetsCorrectType() throws {
        let repos = try makeRepositoriesWithCashTypes()
        defer { TestVaultHelper.cleanup(repos.vault) }

        let checking = try repos.accounts.create(
            name: "Deposit Checking",
            accountClass: AccountClass.checking,
            currencyCode: "USD"
        )
        let income = try repos.categories.create(name: "Salary", type: "income", currencyCode: "USD")

        let created = try repos.transactions.create(
            date: "2026-09-01",
            title: "Paycheck",
            lineItems: [
                (accountId: checking.id, amount: 2500.0, memo: nil),
                (accountId: income.id, amount: -2500.0, memo: nil),
            ],
            transactionType: "deposit"
        )

        #expect(created.transactionType == "Deposit")
        #expect(created.title == "Paycheck")
        #expect(created.lineItems.contains { $0.accountId == checking.id && abs($0.amount - 2500.0) < 0.005 })
    }

    @Test("Create with explicit transaction_type sets Withdrawal")
    func createWithExplicitWithdrawalSetsCorrectType() throws {
        let repos = try makeRepositoriesWithCashTypes()
        defer { TestVaultHelper.cleanup(repos.vault) }

        let checking = try repos.accounts.create(
            name: "Spend Checking",
            accountClass: AccountClass.checking,
            currencyCode: "USD"
        )
        let expense = try repos.categories.create(name: "Groceries", type: "expense", currencyCode: "USD")

        let created = try repos.transactions.create(
            date: "2026-09-01",
            title: "Store",
            lineItems: [
                (accountId: checking.id, amount: -42.50, memo: nil),
                (accountId: expense.id, amount: 42.50, memo: nil),
            ],
            transactionType: "withdrawal"
        )

        #expect(created.transactionType == "Withdrawal")
    }

    @Test("Create infers Deposit from a positive asset line even when Return Of Capital is first")
    func createInfersDepositFromAssetInflow() throws {
        let repos = try makeRepositoriesWithCashTypes()
        defer { TestVaultHelper.cleanup(repos.vault) }

        let checking = try repos.accounts.create(
            name: "Inflow Checking",
            accountClass: AccountClass.checking,
            currencyCode: "USD"
        )
        let income = try repos.categories.create(name: "Interest", type: "income", currencyCode: "USD")

        let created = try repos.transactions.create(
            date: "2026-09-01",
            title: "Interest payment",
            lineItems: [
                (accountId: checking.id, amount: 12.34, memo: nil),
                (accountId: income.id, amount: -12.34, memo: nil),
            ]
        )

        #expect(created.transactionType == "Deposit")
        #expect(created.transactionType != "Return Of Capital")
    }

    @Test("Create infers Withdrawal from a negative asset line")
    func createInfersWithdrawalFromAssetOutflow() throws {
        let repos = try makeRepositoriesWithCashTypes()
        defer { TestVaultHelper.cleanup(repos.vault) }

        let checking = try repos.accounts.create(
            name: "Outflow Checking",
            accountClass: AccountClass.checking,
            currencyCode: "USD"
        )
        let expense = try repos.categories.create(name: "Food", type: "expense", currencyCode: "USD")

        let created = try repos.transactions.create(
            date: "2026-09-01",
            title: "Lunch",
            lineItems: [
                (accountId: checking.id, amount: -18.00, memo: nil),
                (accountId: expense.id, amount: 18.00, memo: nil),
            ]
        )

        #expect(created.transactionType == "Withdrawal")
    }

    @Test("Create infers Transfer when two bank accounts net to zero")
    func createInfersTransferBetweenBankAccounts() throws {
        let repos = try makeRepositoriesWithCashTypes()
        defer { TestVaultHelper.cleanup(repos.vault) }

        let checking = try repos.accounts.create(
            name: "From Checking",
            accountClass: AccountClass.checking,
            currencyCode: "USD"
        )
        let savings = try repos.accounts.create(
            name: "To Savings",
            accountClass: AccountClass.savings,
            currencyCode: "USD"
        )

        let created = try repos.transactions.create(
            date: "2026-09-01",
            title: "Move to savings",
            lineItems: [
                (accountId: checking.id, amount: -200.0, memo: nil),
                (accountId: savings.id, amount: 200.0, memo: nil),
            ]
        )

        #expect(created.transactionType == "Transfer")
    }

    @Test("Create infers Withdrawal for a credit-card purchase")
    func createInfersWithdrawalForCreditCardPurchase() throws {
        let repos = try makeRepositoriesWithCashTypes()
        defer { TestVaultHelper.cleanup(repos.vault) }

        let card = try repos.accounts.create(
            name: "Visa",
            accountClass: AccountClass.creditCard,
            currencyCode: "USD"
        )
        let expense = try repos.categories.create(name: "Shopping", type: "expense", currencyCode: "USD")

        let created = try repos.transactions.create(
            date: "2026-09-01",
            title: "Store charge",
            lineItems: [
                (accountId: card.id, amount: -75.0, memo: nil),
                (accountId: expense.id, amount: 75.0, memo: nil),
            ]
        )

        #expect(created.transactionType == "Withdrawal")
    }

    @Test("Create infers Transfer for a credit-card payment")
    func createInfersTransferForCreditCardPayment() throws {
        let repos = try makeRepositoriesWithCashTypes()
        defer { TestVaultHelper.cleanup(repos.vault) }

        let checking = try repos.accounts.create(
            name: "Payment Checking",
            accountClass: AccountClass.checking,
            currencyCode: "USD"
        )
        let card = try repos.accounts.create(
            name: "Visa",
            accountClass: AccountClass.creditCard,
            currencyCode: "USD"
        )

        let created = try repos.transactions.create(
            date: "2026-09-01",
            title: "Card payment",
            lineItems: [
                (accountId: checking.id, amount: -200.0, memo: nil),
                (accountId: card.id, amount: 200.0, memo: nil),
            ]
        )

        #expect(created.transactionType == "Transfer")
    }

    @Test("Create infers Transfer for a bank transfer with a fee split")
    func createInfersTransferWithFeeSplit() throws {
        let repos = try makeRepositoriesWithCashTypes()
        defer { TestVaultHelper.cleanup(repos.vault) }

        let checking = try repos.accounts.create(
            name: "Fee Checking",
            accountClass: AccountClass.checking,
            currencyCode: "USD"
        )
        let savings = try repos.accounts.create(
            name: "Fee Savings",
            accountClass: AccountClass.savings,
            currencyCode: "USD"
        )
        let expense = try repos.categories.create(name: "Bank Fees", type: "expense", currencyCode: "USD")

        let created = try repos.transactions.create(
            date: "2026-09-01",
            title: "Move to savings with fee",
            lineItems: [
                (accountId: checking.id, amount: -205.0, memo: nil),
                (accountId: savings.id, amount: 200.0, memo: nil),
                (accountId: expense.id, amount: 5.0, memo: nil),
            ]
        )

        #expect(created.transactionType == "Transfer")
    }

    @Test("Create infers Deposit when two splits on the same bank account net to zero")
    func createInfersDepositForSameAccountSplitsNettingZero() throws {
        let repos = try makeRepositoriesWithCashTypes()
        defer { TestVaultHelper.cleanup(repos.vault) }

        let checking = try repos.accounts.create(
            name: "Split Checking",
            accountClass: AccountClass.checking,
            currencyCode: "USD"
        )

        let created = try repos.transactions.create(
            date: "2026-09-01",
            title: "Same-account splits",
            lineItems: [
                (accountId: checking.id, amount: 100.0, memo: "in"),
                (accountId: checking.id, amount: -100.0, memo: "out"),
            ]
        )

        #expect(created.transactionType == "Deposit")
        #expect(created.transactionType != "Transfer")
    }

    @Test("Create with explicit type overrides sign-based inference")
    func createExplicitTypeOverridesInference() throws {
        let repos = try makeRepositoriesWithCashTypes()
        defer { TestVaultHelper.cleanup(repos.vault) }

        let checking = try repos.accounts.create(
            name: "Override Checking",
            accountClass: AccountClass.checking,
            currencyCode: "USD"
        )
        let income = try repos.categories.create(name: "Bonus", type: "income", currencyCode: "USD")

        let created = try repos.transactions.create(
            date: "2026-09-01",
            title: "Forced withdrawal",
            lineItems: [
                (accountId: checking.id, amount: 100.0, memo: nil),
                (accountId: income.id, amount: -100.0, memo: nil),
            ],
            transactionType: "withdrawal"
        )

        #expect(created.transactionType == "Withdrawal")
    }

    @Test("Create rejects an unknown transaction_type")
    func createRejectsUnknownTransactionType() throws {
        let repos = try makeRepositoriesWithCashTypes()
        defer { TestVaultHelper.cleanup(repos.vault) }

        let checking = try repos.accounts.create(
            name: "Unknown Type Checking",
            accountClass: AccountClass.checking,
            currencyCode: "USD"
        )

        do {
            _ = try repos.transactions.create(
                date: "2026-09-01",
                title: "Bad type",
                lineItems: [(accountId: checking.id, amount: 10.0, memo: nil)],
                transactionType: "not-a-real-type"
            )
            Issue.record("Expected unknown transaction type to fail")
        } catch let error as ToolError {
            if case .invalidInput(let message) = error {
                #expect(message.contains("Unknown transaction type"))
                #expect(message.contains("transfer"))
                #expect(!message.contains("short-sell"))
                #expect(!message.contains("buy-to-cover"))
            } else {
                Issue.record("Expected invalidInput, got \(error)")
            }
        } catch {
            Issue.record("Expected ToolError.invalidInput, got \(error)")
        }
    }

    @Test("inferredTransactionTypeName classifies bank-account sign patterns")
    func inferredTransactionTypeNameClassifiesSigns() {
        #expect(TransactionRepository.inferredTransactionTypeName(bankNet: 2500.0, distinctBankAccountCount: 1) == "deposit")
        #expect(TransactionRepository.inferredTransactionTypeName(bankNet: -42.5, distinctBankAccountCount: 1) == "withdrawal")
        #expect(TransactionRepository.inferredTransactionTypeName(bankNet: 0.0, distinctBankAccountCount: 2) == "transfer")
        #expect(TransactionRepository.inferredTransactionTypeName(bankNet: 0.0, distinctBankAccountCount: 1) == "deposit")
        #expect(TransactionRepository.inferredTransactionTypeName(bankNet: -5.0, distinctBankAccountCount: 2) == "transfer")
    }
}
