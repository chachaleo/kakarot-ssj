use utils::errors::{RLPError, RLPHelpersError, RLP_EMPTY_INPUT, RLP_INPUT_TOO_SHORT};
use utils::helpers::{U32Trait, U256Impl, U128Impl, ByteArrayExTrait, ArrayExtension};

// Possible RLP types
#[derive(Drop, PartialEq)]
enum RLPType {
    String,
    List
}

#[derive(Drop, Copy, PartialEq)]
enum RLPItem {
    String: Span<u8>,
    List: Span<RLPItem>
}

#[generate_trait]
impl RLPImpl of RLPTrait {
    /// Returns RLPType from the leading byte with
    /// its offset in the array as well as its size.
    ///
    /// # Arguments
    /// * `input` - Array of byte to decode
    /// # Returns
    /// * `(RLPType, offset, size)` - A tuple containing the RLPType
    /// the offset and the size of the RLPItem to decode
    /// # Errors
    /// * RLPError::EmptyInput - if the input is empty
    /// * RLPError::InputTooShort - if the input is too short for a given
    fn decode_type(input: Span<u8>) -> Result<(RLPType, u32, u32), RLPError> {
        let input_len = input.len();
        if input_len == 0 {
            return Result::Err(RLPError::EmptyInput(RLP_EMPTY_INPUT));
        }

        let prefix_byte = *input[0];

        if prefix_byte < 0x80 { // Char
            Result::Ok((RLPType::String, 0, 1))
        } else if prefix_byte < 0xb8 { // Short String
            Result::Ok((RLPType::String, 1, prefix_byte.into() - 0x80))
        } else if prefix_byte < 0xc0 { // Long String
            let len_bytes_count: u32 = (prefix_byte - 0xb7).into();
            if input_len <= len_bytes_count {
                return Result::Err(RLPError::InputTooShort(RLP_INPUT_TOO_SHORT));
            }
            let string_len_bytes = input.slice(1, len_bytes_count);
            let string_len: u32 = U32Trait::from_bytes(string_len_bytes).unwrap();

            Result::Ok((RLPType::String, 1 + len_bytes_count, string_len))
        } else if prefix_byte < 0xf8 { // Short List
            Result::Ok((RLPType::List, 1, prefix_byte.into() - 0xc0))
        } else { // Long List
            let len_bytes_count = prefix_byte.into() - 0xf7;
            if input.len() <= len_bytes_count {
                return Result::Err(RLPError::InputTooShort(RLP_INPUT_TOO_SHORT));
            }

            let list_len_bytes = input.slice(1, len_bytes_count);
            let list_len: u32 = U32Trait::from_bytes(list_len_bytes).unwrap();
            Result::Ok((RLPType::List, 1 + len_bytes_count, list_len))
        }
    }

    /// RLP encodes a ByteArray, which is the underlying type used to represent
    /// string data in Cairo.  Since RLP encoding is only used for eth_address
    /// computation by calculating the RLP::encode(deployer_address, deployer_nonce)
    /// and then hash it, the input is a ByteArray and not a Span<u8>
    /// # Arguments
    /// * `input` - ByteArray to encode
    /// # Returns
    /// * `ByteArray - RLP encoded ByteArray
    /// # Errors
    /// * RLPError::RlpEmptyInput - if the input is empty
    fn encode_string(input: ByteArray) -> Result<ByteArray, RLPError> {
        let len = input.len();
        if len == 0 {
            return Result::Ok(
                ByteArray { data: Default::default(), pending_word: 0x80, pending_word_len: 1 }
            );
        } else if len == 1 && input[0] < 0x80 {
            return Result::Ok(input);
        } else if len < 56 {
            let mut prefixes: ByteArray = Default::default();
            prefixes.append_byte(0x80 + len.try_into().unwrap());
            let encoding = prefixes + input;
            return Result::Ok(encoding);
        } else {
            let mut prefixes: ByteArray = Default::default();
            let len_as_bytes = len.to_bytes();
            let len_bytes_count = len_as_bytes.len();
            let prefix = 0xb7 + len_bytes_count.try_into().unwrap();
            prefixes.append_byte(prefix);
            prefixes.append_span_bytes(len_as_bytes);
            let encoding = prefixes + input;
            return Result::Ok(encoding);
        }
    }

    /// RLP decodes a rlp encoded byte array
    /// as described in https://ethereum.org/en/developers/docs/data-structures-and-encoding/rlp/
    ///
    /// # Arguments
    /// * `input` - Array of bytes to decode
    /// # Returns
    /// * `Span<RLPItem>` - Span of RLPItem
    /// # Errors
    /// * RLPError::InputTooShort - if the input is too short for a given
    fn decode(input: Span<u8>) -> Result<Span<RLPItem>, RLPError> {
        let mut output: Array<RLPItem> = Default::default();
        let input_len = input.len();

        let (rlp_type, offset, len) = RLPTrait::decode_type(input)?;

        if input_len < offset + len {
            return Result::Err(RLPError::InputTooShort(RLP_INPUT_TOO_SHORT));
        }

        match rlp_type {
            RLPType::String => {
                // checking for default value `0`
                if (len == 0) {
                    output.append(RLPItem::String(array![0].span()));
                } else {
                    output.append(RLPItem::String(input.slice(offset, len)));
                }
            },
            RLPType::List => {
                if len > 0 {
                    let res = RLPTrait::decode(input.slice(offset, len))?;
                    output.append(RLPItem::List(res));
                } else {
                    output.append(RLPItem::List(array![].span()));
                }
            }
        };

        let total_item_len = len + offset;
        if total_item_len < input_len {
            output
                .concat(RLPTrait::decode(input.slice(total_item_len, input_len - total_item_len))?);
        }

        Result::Ok(output.span())
    }
}

#[generate_trait]
impl RLPHelpersImpl of RLPHelpersTrait {
    fn parse_u128_from_string(self: RLPItem) -> Result<u128, RLPHelpersError> {
        match self {
            RLPItem::String(bytes) => {
                let value = U128Impl::from_bytes(bytes).ok_or(RLPHelpersError::FailedParsingU128)?;
                Result::Ok(value)
            },
            RLPItem::List(_) => { Result::Err(RLPHelpersError::NotAString) }
        }
    }

    fn parse_u256_from_string(self: RLPItem) -> Result<u256, RLPHelpersError> {
        match self {
            RLPItem::String(bytes) => {
                let value = U256Impl::from_bytes(bytes).ok_or(RLPHelpersError::FailedParsingU256)?;
                Result::Ok(value)
            },
            RLPItem::List(_) => { Result::Err(RLPHelpersError::NotAString) }
        }
    }


    fn parse_bytes_felt252_from_string(self: RLPItem) -> Result<Span<felt252>, RLPHelpersError> {
        match self {
            RLPItem::String(bytes) => {
                let mut result: Array<felt252> = array![];
                let len = bytes.len();

                let mut i = 0;
                loop {
                    if (i == len) {
                        break ();
                    }
                    result.append((*bytes.at(i)).into());
                    i += 1;
                };

                Result::Ok(result.span())
            },
            RLPItem::List(_) => { Result::Err(RLPHelpersError::NotAString) }
        }
    }
}
