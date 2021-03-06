require 'spec_helper'

require 'puppet/provider/interface/cisco'

provider_class = Puppet::Type.type(:interface).provider(:cisco)

describe provider_class do
  let(:device) { stub_everything 'device' }
  let(:resource) { stub('resource', name: 'Fa0/1') }
  let(:provider) { provider_class.new(device, resource) }

  it 'has a parent of Puppet::Provider::Cisco' do
    expect(provider_class).to be < Puppet::Provider::Cisco
  end

  it 'has an instances method' do
    expect(provider_class).to respond_to(:instances)
  end

  describe 'when looking up instances at prefetch' do
    before(:each) do
      device.stubs(:command).yields(device)
    end

    it 'delegates to the device interface fetcher' do
      device.expects(:interface)
      provider_class.lookup(device, 'Fa0/1')
    end

    it 'returns the given interface data' do
      device.expects(:interface).returns(description: 'thisone', mode: :access)
      expect(provider_class.lookup(device, 'Fa0')).to eq(description: 'thisone', mode: :access)
    end
  end

  describe 'when an instance is being flushed' do
    let(:instance) { provider_class.new(device, ensure: :present, name: 'Fa0/1', description: 'myinterface') }

    it 'calls the device interface update method with current and past properties' do
      instance.description = 'newdesc'
      instance.resource = resource
      resource.stubs(:[]).with(:name).returns('Fa0/1')
      device = stub_everything 'device'
      instance.stubs(:device).returns(device)
      device.expects(:command).yields(device)
      interface = stub 'interface'
      device.expects(:new_interface).with('Fa0/1').returns(interface)
      interface.expects(:update).with({ ensure: :present, name: 'Fa0/1', description: 'myinterface' },
                                      ensure: :present, name: 'Fa0/1', description: 'newdesc')

      instance.flush
    end
  end
end
