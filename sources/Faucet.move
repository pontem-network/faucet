/// Basic faucet, allows to request coins between intervals.
module Account::Faucet {
    use Std::Signer;
    use Std::Errors;
    use AptosFramework::Timestamp;
    use AptosFramework::Coin::{Self, Coin};

    // Errors.

    /// When Faucet already exists on account.
    const ERR_FAUCET_EXISTS: u64 = 100;

    /// When Faucet doesn't exists on account.
    const ERR_FAUCET_NOT_EXISTS: u64 = 101;

    /// When user already got coins and currently restricted to request more funds.
    const ERR_RESTRICTED: u64 = 102;

    /// Faucet data.
    struct Faucet<phantom CoinType> has key {
        /// Faucet balance.
        deposit: Coin<CoinType>,
        /// How much coins should be sent to user per request.
        per_request: u64,
        /// Period between requests to faucet in seconds.
        period: u64,
    }

    /// If user has this resource on his account - he's not able to get more funds if (current_timestamp < since + period).
    struct Restricted<phantom Faucet> has key {
        since: u64,
    }

    // Public functions.

    /// Create a new faucet on `account` address.
    /// * `deposit` - initial coins on faucet balance.
    /// * `per_request` - how much funds should be distributed per user request.
    /// * `period` - interval allowed between requests for specific user.
    public fun create_faucet_internal<CoinType>(account: &signer, deposit: Coin<CoinType>, per_request: u64, period: u64) {
        let account_addr = Signer::address_of(account);

        assert!(!exists<Faucet<CoinType>>(account_addr), Errors::already_published(ERR_FAUCET_EXISTS));

        move_to(account, Faucet<CoinType> {
            deposit,
            per_request,
            period
        });
    }

    /// Change settings of faucet `CoinType`.
    /// * `per_request` - how much funds should be distributed per user request.
    /// * `period` - interval allowed between requests for specific user.
    public fun change_settings_internal<CoinType>(account: &signer, per_request: u64, period: u64) acquires Faucet {
        let account_addr = Signer::address_of(account);

        assert!(exists<Faucet<CoinType>>(account_addr), Errors::not_published(ERR_FAUCET_NOT_EXISTS));

        let faucet = borrow_global_mut<Faucet<CoinType>>(account_addr);
        faucet.per_request = per_request;
        faucet.period = period;
    }

    /// Deposist more coins `CoinType` to faucet.
    public fun deposit_internal<CoinType>(faucet_addr: address, deposit: Coin<CoinType>) acquires Faucet {
        assert!(exists<Faucet<CoinType>>(faucet_addr), Errors::not_published(ERR_FAUCET_NOT_EXISTS));

        let faucet = borrow_global_mut<Faucet<CoinType>>(faucet_addr);
        Coin::merge(&mut faucet.deposit, deposit);
    }

    /// Requests coins `CoinType` from faucet `faucet_addr`.
    public fun request_internal<CoinType>(account: &signer, faucet_addr: address): Coin<CoinType> acquires Faucet, Restricted {
        let account_addr = Signer::address_of(account);

        assert!(exists<Faucet<CoinType>>(faucet_addr), Errors::not_published(ERR_FAUCET_NOT_EXISTS));

        let faucet = borrow_global_mut<Faucet<CoinType>>(faucet_addr);
        let coins = Coin::extract(&mut faucet.deposit, faucet.per_request);

        let now = Timestamp::now_seconds();

        if (exists<Restricted<CoinType>>(account_addr)) {
            let restricted = borrow_global_mut<Restricted<CoinType>>(account_addr);
            assert!(restricted.since + faucet.period <= now, Errors::invalid_argument(ERR_RESTRICTED));
            restricted.since = now;
        } else {
            move_to(account, Restricted<CoinType> {
                since: now,
            });
        };

        coins
    }

    // Scripts.

    /// Creates new faucet on `account` address for coin `CoinType`.
    /// * `account` - account which creates
    /// * `per_request` - how much funds should be distributed per user request.
    /// * `period` - interval allowed between requests for specific user.
    public(script) fun create_faucet<CoinType>(account: &signer, amount_to_deposit: u64, per_request: u64, period: u64) {
        let coins = Coin::withdraw<CoinType>(account, amount_to_deposit);

        create_faucet_internal(account, coins, per_request, period);
    }

    /// Changes faucet settings on `account`.
    public(script) fun change_settings<CoinType>(account: &signer, per_request: u64, period: u64) acquires Faucet {
        change_settings_internal<CoinType>(account, per_request, period);
    }

    /// Deposits coins `CoinType` to faucet on `faucet` address, withdrawing funds from user balance.
    public(script) fun deposit<CoinType>(account: &signer, faucet_addr: address, amount: u64) acquires Faucet {
        let coins = Coin::withdraw<CoinType>(account, amount);

        deposit_internal<CoinType>(faucet_addr, coins);
    }

    /// Deposits coins `CoinType` from faucet on user's account.
    /// `faucet` - address of faucet to request funds.
    public(script) fun request<CoinType>(account: &signer, faucet_addr: address) acquires Faucet, Restricted {
        let account_addr = Signer::address_of(account);

        if (!Coin::is_account_registered<CoinType>(account_addr)) {
            Coin::register<CoinType>(account);
        };

        let coins = request_internal<CoinType>(account, faucet_addr);

        Coin::deposit(account_addr, coins);
    }

    #[test_only]
    use AptosFramework::Genesis;
    #[test_only]
    use Std::ASCII::string;

    #[test_only]
    struct FakeMoney has store {}

    #[test_only]
    struct FakeMoneyCaps has key {
        mint_cap: Coin::MintCapability<FakeMoney>,
        burn_cap: Coin::BurnCapability<FakeMoney>,
    }

    #[test(core = @CoreResources, faucet_creator = @Account, someone_else = @0x11)]
    public(script) fun test_faucet_end_to_end(core: &signer, faucet_creator: &signer, someone_else: &signer) acquires Faucet, Restricted {
        Genesis::setup(core);

        let (m, b) = Coin::initialize<FakeMoney>(
            faucet_creator,
            string(b"FakeMoney"),
            string(b"FM"),
            8,
            true
        );

        let amount = 100000000000000u64;
        let per_request = 1000000000u64;
        let period = 3000u64;

        let faucet_addr = Signer::address_of(faucet_creator);

        let coins_minted = Coin::mint(amount, &m);
        Coin::register<FakeMoney>(faucet_creator);
        Coin::deposit(faucet_addr, coins_minted);

        create_faucet<FakeMoney>(faucet_creator, amount / 2, per_request, period);

        request<FakeMoney>(faucet_creator, faucet_addr);
        assert!(Coin::balance<FakeMoney>(faucet_addr) == (amount / 2 + per_request), 0);

        let someone_else_addr = Signer::address_of(someone_else);
        request<FakeMoney>(someone_else, faucet_addr);
        assert!(Coin::balance<FakeMoney>(someone_else_addr) == per_request, 1);

        Timestamp::update_global_time_for_test(3000000000);

        let new_per_request = 2000000000u64;
        change_settings<FakeMoney>(faucet_creator, new_per_request, period);

        request<FakeMoney>(someone_else, faucet_addr);
        assert!(Coin::balance<FakeMoney>(someone_else_addr) == (per_request + new_per_request), 2);


        change_settings<FakeMoney>(faucet_creator, new_per_request, 5000);
        let to_check = borrow_global<Faucet<FakeMoney>>(faucet_addr);
        assert!(to_check.period == 5000, 3);
        assert!(to_check.per_request == new_per_request, 4);

        deposit<FakeMoney>(someone_else, faucet_addr, new_per_request);
        assert!(Coin::balance<FakeMoney>(someone_else_addr) == per_request, 5);

        move_to(faucet_creator, FakeMoneyCaps {
            mint_cap: m,
            burn_cap: b,
        });
    }

    #[test(core = @CoreResources, faucet_creator = @Account)]
    #[expected_failure(abort_code = 26119)]
    public(script) fun test_faucet_fail_request(core: &signer, faucet_creator: &signer) acquires Faucet, Restricted {
        Genesis::setup(core);

        let (m, b) = Coin::initialize<FakeMoney>(
            faucet_creator,
            string(b"FakeMoney"),
            string(b"FM"),
            8,
            true
        );

        let amount = 100000000000000u64;
        let per_request = 1000000000u64;
        let period = 3000u64;

        let faucet_addr = Signer::address_of(faucet_creator);

        let coins_minted = Coin::mint(amount, &m);
        Coin::register<FakeMoney>(faucet_creator);
        Coin::deposit(faucet_addr, coins_minted);

        create_faucet<FakeMoney>(faucet_creator, amount / 2, per_request, period);

        request<FakeMoney>(faucet_creator, faucet_addr);
        request<FakeMoney>(faucet_creator, faucet_addr);
        assert!(Coin::balance<FakeMoney>(faucet_addr) == (amount / 2 + per_request), 0);

        move_to(faucet_creator, FakeMoneyCaps{
            mint_cap: m,
            burn_cap: b,
        });
    }

    #[test(core = @CoreResources, faucet_creator = @Account, someone_else = @0x11)]
    #[expected_failure(abort_code = 25861)]
    public(script) fun test_faucet_fail_settings(core: &signer, faucet_creator: &signer, someone_else: &signer) acquires Faucet {
        Genesis::setup(core);

        let (m, b) = Coin::initialize<FakeMoney>(
            faucet_creator,
            string(b"FakeMoney"),
            string(b"FM"),
            8,
            true
        );

        let amount = 100000000000000u64;
        let per_request = 1000000000u64;
        let period = 3000u64;

        let faucet_addr = Signer::address_of(faucet_creator);

        let coins_minted = Coin::mint(amount, &m);
        Coin::register<FakeMoney>(faucet_creator);
        Coin::deposit(faucet_addr, coins_minted);

        create_faucet<FakeMoney>(faucet_creator, amount / 2, per_request, period);
        change_settings<FakeMoney>(someone_else, 1, 1);

        move_to(faucet_creator, FakeMoneyCaps{
            mint_cap: m,
            burn_cap: b,
        });
    }

    #[test(core = @CoreResources, faucet_creator = @Account)]
    #[expected_failure(abort_code = 25606)]
    public(script) fun test_already_exists(core: &signer, faucet_creator: &signer) {
        Genesis::setup(core);

        let (m, b) = Coin::initialize<FakeMoney>(
            faucet_creator,
            string(b"FakeMoney"),
            string(b"FM"),
            8,
            true
        );

        let amount = 100000000000000u64;
        let per_request = 1000000000u64;
        let period = 3000u64;

        let faucet_addr = Signer::address_of(faucet_creator);

        let coins_minted = Coin::mint(amount, &m);
        Coin::register<FakeMoney>(faucet_creator);
        Coin::deposit(faucet_addr, coins_minted);

        create_faucet<FakeMoney>(faucet_creator, amount / 2, per_request, period);
        create_faucet<FakeMoney>(faucet_creator, amount / 2, per_request, period);

        move_to(faucet_creator, FakeMoneyCaps{
            mint_cap: m,
            burn_cap: b,
        });
    }
}