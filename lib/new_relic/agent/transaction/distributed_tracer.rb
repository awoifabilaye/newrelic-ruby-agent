# encoding: utf-8
# This file is distributed under New Relic's license terms.
# See https://github.com/newrelic/rpm/blob/master/LICENSE for complete details.
# frozen_string_literal: true

require 'new_relic/agent/transaction/trace_context'
require 'new_relic/agent/transaction/distributed_tracing'
require 'new_relic/agent/distributed_tracing/cross_app_tracing'

module NewRelic
  module Agent
    class Transaction
      class DistributedTracer
        W3C_FORMAT        = "w3c" # TODO: REMOVE?
        NEWRELIC_HEADER   = "newrelic"
        CANDIDATE_HEADERS = [
          NEWRELIC_HEADER,
          'NEWRELIC',
          'NewRelic',
          'Newrelic'
        ].freeze


        include NewRelic::Agent::CrossAppTracing
        include DistributedTracing
        include TraceContext

        attr_reader :transaction
        attr_accessor :parent_transaction_id

        def parent_guid
          if trace_context_header_data
            trace_context_header_data.parent_id
          elsif distributed_trace_payload
            distributed_trace_payload.id
          end
        end

        def accept_incoming_request request
          accept_incoming_transport_type request
          if trace_parent_header_present? request
            accept_trace_context_incoming_request request
          else
            accept_distributed_tracing_incoming_request request
          end
        end

        def caller_transport_type
          @caller_transport_type ||= "Unknown"
        end

        def accept_incoming_transport_type request
          @caller_transport_type = DistributedTraceTransportType.for_rack_request request
        end

        def initialize transaction
          @transaction = transaction
        end

        def record_metrics
          record_cross_app_metrics
          DistributedTraceMetrics.record_metrics_for_transaction transaction
        end

        def append_payload payload
          append_cat_info payload
          append_distributed_trace_info payload
          append_trace_context_info payload
        end

        def insert_headers request
          insert_trace_context_headers request
          insert_distributed_trace_header request
          insert_cross_app_header request
        end

        def consume_message_headers headers, tracer_state, transport_type
          consume_message_distributed_tracing_headers headers, transport_type
          consume_message_cross_app_tracing_headers headers, tracer_state
          consume_message_synthetics_headers headers
        rescue => e
          NewRelic::Agent.logger.error "Error in consume_message_headers", e
        end

        def assign_intrinsics
          if Agent.config[:'distributed_tracing.enabled'] || trace_context_active?
            DistributedTraceIntrinsics.copy_to_attributes transaction.payload, transaction.attributes
          elsif is_cross_app?
            assign_cross_app_intrinsics
          end
        end

        private

        def consume_message_synthetics_headers headers
          synthetics_header = headers[CrossAppTracing::NR_MESSAGE_BROKER_SYNTHETICS_HEADER]
          if synthetics_header and
             incoming_payload = ::JSON.load(deobfuscate(synthetics_header)) and
             SyntheticsMonitor.is_valid_payload?(incoming_payload) and
             SyntheticsMonitor.is_supported_version?(incoming_payload) and
             SyntheticsMonitor.is_trusted?(incoming_payload)

            transaction.raw_synthetics_header = synthetics_header
            transaction.synthetics_payload = incoming_payload
          end
        rescue => e
          NewRelic::Agent.logger.error "Error in consume_message_synthetics_header", e
        end

        def consume_message_distributed_tracing_headers headers, transport_type
          return unless Agent.config[:'distributed_tracing.enabled']
          return unless newrelic_trace_key = CANDIDATE_HEADERS.detect do |key|
            headers.has_key?(key)
          end

          accept_incoming_transport_type transport_type
          return unless payload = headers[newrelic_trace_key]

          accept_distributed_trace_payload payload
        end

        def consume_message_cross_app_tracing_headers headers, tracer_state
          return unless CrossAppTracing.cross_app_enabled?
          return unless CrossAppTracing.message_has_crossapp_request_header?(headers)

          accept_cross_app_payload headers, tracer_state
          CrossAppTracing.assign_intrinsic_transaction_attributes tracer_state
        end

        def accept_cross_app_payload headers, tracer_state
          encoded_id = headers[CrossAppTracing::NR_MESSAGE_BROKER_ID_HEADER]
          decoded_id = encoded_id.nil? ? EMPTY_STRING : deobfuscate(encoded_id)

          return unless CrossAppTracing.trusted_valid_cross_app_id?(decoded_id)
          txn_header = headers[CrossAppTracing::NR_MESSAGE_BROKER_TXN_HEADER]
          txn_info   = ::JSON.load(deobfuscate(txn_header))
          payload    = CrossAppPayload.new(decoded_id, transaction, txn_info)

          @cross_app_payload = payload
        rescue => e
          NewRelic::Agent.logger.debug("Failure deserializing encoded header in #{self.class}, #{e.class}, #{e.message}")
          nil
        end

        def deobfuscate message
          CrossAppTracing.obfuscator.deobfuscate message
        end

        def insert_trace_context_headers request
          insert_trace_context carrier: request
        end

        def insert_distributed_trace_header request
          return unless Agent.config[:'distributed_tracing.enabled']
          payload = create_distributed_trace_payload
          request[NEWRELIC_HEADER] = payload.http_safe if payload
        end

      end
    end
  end
end

