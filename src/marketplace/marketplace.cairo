use array::SpanTrait;
use zeroable::Zeroable;
use rules_utils::utils::serde::SpanSerde;

// locals
use super::interface::{ Voucher, DeploymentData, Order };

#[abi]
trait MarketplaceABI {
  #[external]
  fn fulfill_order(offerer: starknet::ContractAddress, order: Order, signature: Span<felt252>);

  #[external]
  fn cancel_order(order: Order, signature: Span<felt252>);

  #[external]
  fn fulfill_order_with_voucher(
    voucher: Voucher,
    voucher_signature: Span<felt252>,
    order: Order,
    order_signature: Span<felt252>,
    offerer_deployment_data: DeploymentData,
  );
}

#[contract]
mod Marketplace {
  use array::{ ArrayTrait, SpanTrait };
  use zeroable::Zeroable;

  // locals
  use marketplace::access::ownable::Ownable;
  use rules_utils::utils::zeroable::U256Zeroable;
  use super::super::interface::IMarketplace;
  use super::super::messages::MarketplaceMessages;
  use super::{ Order, Voucher, DeploymentData };
  use super::super::order::Item;

  // dispatchers
  use marketplace::introspection::erc165::{ IERC165Dispatcher, IERC165DispatcherTrait };
  use marketplace::royalties::erc2981::{ IERC2981_ID, IERC2981Dispatcher, IERC2981DispatcherTrait };
  use marketplace::token::erc20::{ IERC20Dispatcher, IERC20DispatcherTrait };
  use marketplace::token::erc1155::{ IERC1155Dispatcher, IERC1155DispatcherTrait };
  use marketplace::token::lazy_minter::{ ILazyMinterDispatcher, ILazyMinterDispatcherTrait };

  //
  // Events
  //

  #[event]
  fn FulfillOrder(
    hash: felt252,
    offerer: starknet::ContractAddress,
    offeree: starknet::ContractAddress,
    offer_item: Item,
    consideration_item: Item,
  ) {}

  #[event]
  fn CancelOrder(
    hash: felt252,
    offerer: starknet::ContractAddress,
    offer_item: Item,
    consideration_item: Item,
  ) {}

  //
  // Constructor
  //

  #[constructor]
  fn constructor(owner_: starknet::ContractAddress) {
    initializer(:owner_);
  }

  //
  // impls
  //

  impl Marketplace of IMarketplace {
    fn fulfill_order(offerer: starknet::ContractAddress, order: Order, signature: Span<felt252>) {
      let hash = MarketplaceMessages::consume_valid_order_from_deployed(from: offerer, :order, :signature);

      // get potential royalties info
      let (royalties_receiver, royalties_amount) = _royalty_info(
        offer_item: order.offer_item,
        consideration_item: order.consideration_item
      );

      // transfer offer to caller
      let caller = starknet::get_caller_address();

      _transfer_item_with_royalties_from(
        from: offerer,
        to: caller,
        item: order.offer_item,
        :royalties_receiver,
        :royalties_amount
      );

      // transfer consideration to offerer
      _transfer_item_with_royalties_from(
        from: caller,
        to: offerer,
        item: order.consideration_item,
        :royalties_receiver,
        :royalties_amount
      );

      // Events
      FulfillOrder(
        :hash,
        :offerer,
        offeree: caller,
        offer_item: order.offer_item,
        consideration_item: order.consideration_item
      );
    }

    fn cancel_order(order: Order, signature: Span<felt252>) {
      let caller = starknet::get_caller_address();

      let hash = MarketplaceMessages::consume_valid_order_from_deployed(from: caller, :order, :signature);

      // Events
      CancelOrder(
        :hash,
        offerer: caller,
        offer_item: order.offer_item,
        consideration_item: order.consideration_item
      );
    }

    fn fulfill_order_with_voucher(
      voucher: Voucher,
      voucher_signature: Span<felt252>,
      order: Order,
      order_signature: Span<felt252>,
      offerer_deployment_data: DeploymentData,
    ) {
      let mut hash = 0;
      let offerer = voucher.receiver;

      hash = MarketplaceMessages::consume_valid_order_from(
        from: offerer,
        deployment_data: offerer_deployment_data,
        :order,
        signature: order_signature
      );

      // assert voucher and order offer item match
      match order.offer_item {
        Item::Native(()) => { panic_with_felt252('Unsupported item type'); },

        Item::ERC20(erc_20_item) => {
          assert(voucher.token_id.is_zero(), 'Invalid voucher and order match');
          assert(voucher.amount == erc_20_item.amount, 'Invalid voucher and order match');
        },

        Item::ERC721(()) => { panic_with_felt252('Unsupported item type'); },

        Item::ERC1155(erc_1155_item) => {
          assert(voucher.token_id == erc_1155_item.identifier, 'Invalid voucher and order match');
          assert(voucher.amount == erc_1155_item.amount, 'Invalid voucher and order match');
        }
      }

      // get potential royalties info
      let (royalties_receiver, royalties_amount) = _royalty_info(
        offer_item: order.offer_item,
        consideration_item: order.consideration_item
      );

      // mint offer to caller
      let caller = starknet::get_caller_address();

      _transfer_item_with_voucher(to: caller, item: order.offer_item, :voucher, :voucher_signature);

      // transfer consideration to offerer
      _transfer_item_with_royalties_from(
        from: caller,
        to: offerer,
        item: order.consideration_item,
        :royalties_receiver,
        :royalties_amount
      );

      // Events
      FulfillOrder(
        :hash,
        :offerer,
        offeree: caller,
        offer_item: order.offer_item,
        consideration_item: order.consideration_item
      );
    }
  }

  //
  // Upgrade
  //

  // TODO: use Upgradeable impl with more custom call after upgrade
  #[external]
  fn upgrade(new_implementation: starknet::ClassHash) {
    // Modifiers
    Ownable::assert_only_owner();

    // Body

    // set new impl
    starknet::replace_class_syscall(new_implementation);
  }

  // Getters

  #[view]
  fn owner() -> starknet::ContractAddress {
    Ownable::owner()
  }

  // Ownable

  #[external]
  fn transfer_ownership(new_owner: starknet::ContractAddress) {
    Ownable::transfer_ownership(:new_owner);
  }

  #[external]
  fn renounce_ownership() {
    Ownable::renounce_ownership();
  }

  // Order

  #[external]
  fn fulfill_order(offerer: starknet::ContractAddress, order: Order, signature: Span<felt252>) {
    Marketplace::fulfill_order(:offerer, :order, :signature);
  }

  #[external]
  fn cancel_order(order: Order, signature: Span<felt252>) {
    Marketplace::cancel_order(:order, :signature);
  }

  #[external]
  fn fulfill_order_with_voucher(
    voucher: Voucher,
    voucher_signature: Span<felt252>,
    order: Order,
    order_signature: Span<felt252>,
    offerer_deployment_data: DeploymentData,
  ) {
    Marketplace::fulfill_order_with_voucher(
      :voucher,
      :voucher_signature,
      :order,
      :order_signature,
      :offerer_deployment_data
    );
  }

  //
  // Internals
  //

  // Init

  #[internal]
  fn initializer(owner_: starknet::ContractAddress) {
    Ownable::_transfer_ownership(new_owner: owner_);
  }

  // Royalties

  #[internal]
  fn _royalty_info(offer_item: Item, consideration_item: Item) -> (starknet::ContractAddress, u256) {
    match offer_item {
      Item::Native(()) => { panic_with_felt252('Unsupported item type'); },

      Item::ERC20(erc_20_item) => {
        return _item_royalty_info(item: consideration_item, sale_price: erc_20_item.amount);
      },

      Item::ERC721(()) => { panic_with_felt252('Unsupported item type'); },

      Item::ERC1155(erc_1155_item) => {},
    }

    match consideration_item {
      Item::Native(()) => { panic_with_felt252('Unsupported item type'); },

      Item::ERC20(erc_20_item) => {
        return _item_royalty_info(item: offer_item, sale_price: erc_20_item.amount);
      },

      Item::ERC721(()) => { panic_with_felt252('Unsupported item type'); },

      Item::ERC1155(erc_1155_item) => {},
    }

    ZERO_ROYALTIES()
  }

  #[internal]
  fn _item_royalty_info(item: Item, sale_price: u256) -> (starknet::ContractAddress, u256) {
    match item {
      Item::Native(()) => { panic_with_felt252('Unsupported item type'); },

      Item::ERC20(erc_20_item) => {},

      Item::ERC721(()) => { panic_with_felt252('Unsupported item type'); },

      Item::ERC1155(erc_1155_item) => {
        let ERC165 = IERC165Dispatcher { contract_address: erc_1155_item.token };

        // check if token support ERC2981 royalties standard
        if (ERC165.supports_interface(IERC2981_ID)) {
          let ERC2981 = IERC2981Dispatcher { contract_address: erc_1155_item.token };

          // return royalty infos from token
          return ERC2981.royalty_info(token_id: erc_1155_item.identifier, :sale_price);
        }
      },
    }

    ZERO_ROYALTIES()
  }

  #[internal]
  fn ZERO_ROYALTIES() -> (starknet::ContractAddress, u256) {
    (starknet::contract_address_const::<0>(), 0)
  }

  // Order

  #[internal]
  fn _transfer_item_with_royalties_from(
    from: starknet::ContractAddress,
    to: starknet::ContractAddress,
    item: Item,
    royalties_receiver: starknet::ContractAddress,
    royalties_amount: u256
  ) {
    // TODO: add case fallback support

    match item {
      Item::Native(()) => { panic_with_felt252('Unsupported item type'); },

      Item::ERC20(erc_20_item) => {
        let ERC20 = IERC20Dispatcher { contract_address: erc_20_item.token };

        ERC20.transferFrom(sender: from, recipient: to, amount: erc_20_item.amount - royalties_amount);

        // transfer royalties
        if (royalties_amount.is_non_zero()) {
          ERC20.transferFrom(sender: from, recipient: royalties_receiver, amount: royalties_amount);
        }
      },

      Item::ERC721(()) => { panic_with_felt252('Unsupported item type'); },

      Item::ERC1155(erc_1155_item) => {
        let ERC1155 = IERC1155Dispatcher { contract_address: erc_1155_item.token };

        ERC1155.safe_transfer_from(
          :from,
          :to,
          id: erc_1155_item.identifier,
          amount: erc_1155_item.amount,
          data: ArrayTrait::<felt252>::new().span()
        );
      },
    }
  }

  #[internal]
  fn _transfer_item_with_voucher(
    to: starknet::ContractAddress,
    item: Item,
    voucher: Voucher,
    voucher_signature: Span<felt252>
  ) {
    // TODO: add case fallback support

    let mut token: starknet::ContractAddress = starknet::contract_address_const::<0>();

    match item {
      Item::Native(()) => { panic_with_felt252('Unsupported item type'); },

      // Does not support ERC20 redeem, otherwise we should implement a way to retrieve royalties
      Item::ERC20(erc_20_item) => { panic_with_felt252('Cannot redeem ERC20 voucher'); },

      Item::ERC721(()) => { panic_with_felt252('Unsupported item type'); },

      Item::ERC1155(erc_1155_item) => {
        token = erc_1155_item.token
      },
    }

    let LazyMinter = ILazyMinterDispatcher { contract_address: token };
    LazyMinter.redeem_voucher_to(:to, :voucher, signature: voucher_signature);
  }
}
