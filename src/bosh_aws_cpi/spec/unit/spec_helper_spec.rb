require 'spec_helper'

describe 'spec_helper' do
  it 'merges a flat hash' do
    base_hash = {
        a: 5,
        b: 6
    }

    override_hash = {
        c: 4
    }

    expect(mock_cloud_options_merge override_hash, base_hash).to eq({a: 5, b:6, c:4})
  end

  it 'merges a nested hash' do
    base_hash = {
        a: 5,
        b: 6,
        c: {
            d: 7,
            f: 8
        }
    }

    override_hash = {
        b: 9,
        c: {
            f: 10
        }
    }

    expected_result = {
        a: 5,
        b: 9,
        c: {
            d: 7,
            f: 10
        }
    }
    expect(mock_cloud_options_merge override_hash, base_hash).to eq(expected_result)
  end

  it 'merges a nested hash with nil value' do
    base_hash = {
        a: 5,
        b: 6,
        c: {
            d: 7,
            f: 8
        }
    }

    override_hash = {
        b: 9,
        c: nil
    }

    expected_result = {
        a: 5,
        b: 9,
        c: nil
    }
    expect(mock_cloud_options_merge override_hash, base_hash).to eq(expected_result)
  end

  it 'does not break, if override_hash is nil' do
    base_hash = {
        a: 5,
        b: 6,
        c: {
            d: 7,
            f: 8
        }
    }

    override_hash = nil

    expect(mock_cloud_options_merge override_hash, base_hash).to eq(base_hash)
  end

end
