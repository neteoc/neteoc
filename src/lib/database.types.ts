export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[];

export type Database = {
  public: {
    Tables: {
      features: {
        Row: {
          created_at: string;
          created_by: string;
          description: string | null;
          geom: unknown;
          id: string;
          layer_id: string;
          organization_id: string;
          properties: NonNullable<Json>;
          revision: number;
          status: string | null;
          title: string;
          updated_at: string;
          updated_by: string;
        };
        ComputedFields: never;
        Insert: {
          created_at?: string;
          created_by: string;
          description?: string | null;
          geom: unknown;
          id?: string;
          layer_id: string;
          organization_id: string;
          properties?: NonNullable<Json>;
          revision?: number;
          status?: string | null;
          title: string;
          updated_at?: string;
          updated_by: string;
        };
        Update: {
          created_at?: string;
          created_by?: string;
          description?: string | null;
          geom?: unknown;
          id?: string;
          layer_id?: string;
          organization_id?: string;
          properties?: NonNullable<Json>;
          revision?: number;
          status?: string | null;
          title?: string;
          updated_at?: string;
          updated_by?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'features_layer_organization_fkey';
            columns: ['layer_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'layers';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      layers: {
        Row: {
          created_at: string;
          id: string;
          organization_id: string;
          title: string;
        };
        ComputedFields: never;
        Insert: {
          created_at?: string;
          id?: string;
          organization_id: string;
          title: string;
        };
        Update: {
          created_at?: string;
          id?: string;
          organization_id?: string;
          title?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'layers_organization_id_fkey';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
        ];
      };
      map_layers: {
        Row: {
          created_at: string;
          default_visible: boolean;
          layer_id: string;
          map_id: string;
          organization_id: string;
          position: number;
        };
        ComputedFields: never;
        Insert: {
          created_at?: string;
          default_visible?: boolean;
          layer_id: string;
          map_id: string;
          organization_id: string;
          position: number;
        };
        Update: {
          created_at?: string;
          default_visible?: boolean;
          layer_id?: string;
          map_id?: string;
          organization_id?: string;
          position?: number;
        };
        Relationships: [
          {
            foreignKeyName: 'map_layers_layer_organization_fkey';
            columns: ['layer_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'layers';
            referencedColumns: ['id', 'organization_id'];
          },
          {
            foreignKeyName: 'map_layers_map_organization_fkey';
            columns: ['map_id', 'organization_id'];
            isOneToOne: false;
            referencedRelation: 'maps';
            referencedColumns: ['id', 'organization_id'];
          },
        ];
      };
      maps: {
        Row: {
          created_at: string;
          description: string | null;
          id: string;
          organization_id: string;
          title: string;
        };
        ComputedFields: never;
        Insert: {
          created_at?: string;
          description?: string | null;
          id?: string;
          organization_id: string;
          title: string;
        };
        Update: {
          created_at?: string;
          description?: string | null;
          id?: string;
          organization_id?: string;
          title?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'maps_organization_id_fkey';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
        ];
      };
      memberships: {
        Row: {
          created_at: string;
          organization_id: string;
          role: Database['public']['Enums']['organization_role'];
          user_id: string;
        };
        ComputedFields: never;
        Insert: {
          created_at?: string;
          organization_id: string;
          role: Database['public']['Enums']['organization_role'];
          user_id: string;
        };
        Update: {
          created_at?: string;
          organization_id?: string;
          role?: Database['public']['Enums']['organization_role'];
          user_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'memberships_organization_id_fkey';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
        ];
      };
      organization_invitations: {
        Row: {
          consumed_at: string | null;
          consumed_by: string | null;
          created_at: string;
          created_by: string;
          email: string;
          expires_at: string;
          id: string;
          organization_id: string;
          revoked_at: string | null;
          revoked_by: string | null;
          role: Database['public']['Enums']['organization_role'];
          token_digest: string;
        };
        ComputedFields: never;
        Insert: {
          consumed_at?: string | null;
          consumed_by?: string | null;
          created_at?: string;
          created_by: string;
          email: string;
          expires_at: string;
          id?: string;
          organization_id: string;
          revoked_at?: string | null;
          revoked_by?: string | null;
          role: Database['public']['Enums']['organization_role'];
          token_digest: string;
        };
        Update: {
          consumed_at?: string | null;
          consumed_by?: string | null;
          created_at?: string;
          created_by?: string;
          email?: string;
          expires_at?: string;
          id?: string;
          organization_id?: string;
          revoked_at?: string | null;
          revoked_by?: string | null;
          role?: Database['public']['Enums']['organization_role'];
          token_digest?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'organization_invitations_organization_id_fkey';
            columns: ['organization_id'];
            isOneToOne: false;
            referencedRelation: 'organizations';
            referencedColumns: ['id'];
          },
        ];
      };
      organizations: {
        Row: {
          created_at: string;
          id: string;
          name: string;
        };
        ComputedFields: never;
        Insert: {
          created_at?: string;
          id?: string;
          name: string;
        };
        Update: {
          created_at?: string;
          id?: string;
          name?: string;
        };
        Relationships: [];
      };
    };
    Views: {
      [_ in never]: never;
    };
    Functions: {
      accept_organization_invitation: {
        Args: { p_token: string };
        Returns: string;
      };
      issue_organization_invitation: {
        Args: {
          p_email: string;
          p_lifetime?: string;
          p_organization_id: string;
          p_role: Database['public']['Enums']['organization_role'];
        };
        Returns: string;
      };
      list_layer_features: {
        Args: {
          p_after_created_at?: string;
          p_after_id?: string;
          p_byte_budget?: number;
          p_layer_id: string;
          p_limit?: number;
          p_max_lat?: number;
          p_max_lon?: number;
          p_min_lat?: number;
          p_min_lon?: number;
        };
        Returns: Json;
      };
      reorder_map_layers: {
        Args: { p_layer_ids: string[]; p_map_id: string };
        Returns: undefined;
      };
      revoke_organization_invitation: {
        Args: { p_invitation_id: string };
        Returns: undefined;
      };
    };
    Enums: {
      organization_role: 'admin' | 'editor' | 'viewer';
    };
    CompositeTypes: {
      [_ in never]: never;
    };
  };
};

type DatabaseWithoutInternals = Omit<Database, '__InternalSupabase'>;

type DefaultSchema = DatabaseWithoutInternals[Extract<
  keyof Database,
  'public'
>];

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema['Tables'] & DefaultSchema['Views'])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions['schema']]['Tables'] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions['schema']]['Views'])
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals;
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions['schema']]['Tables'] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions['schema']]['Views'])[TableName] extends {
      Row: infer R;
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema['Tables'] &
        DefaultSchema['Views'])
    ? (DefaultSchema['Tables'] &
        DefaultSchema['Views'])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R;
      }
      ? R
      : never
    : never;

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    keyof DefaultSchema['Tables'] | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions['schema']]['Tables']
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals;
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions['schema']]['Tables'][TableName] extends {
      Insert: infer I;
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema['Tables']
    ? DefaultSchema['Tables'][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I;
      }
      ? I
      : never
    : never;

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    keyof DefaultSchema['Tables'] | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions['schema']]['Tables']
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals;
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions['schema']]['Tables'][TableName] extends {
      Update: infer U;
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema['Tables']
    ? DefaultSchema['Tables'][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U;
      }
      ? U
      : never
    : never;

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    keyof DefaultSchema['Enums'] | { schema: keyof DatabaseWithoutInternals },
  EnumName extends (DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions['schema']]['Enums']
    : never) = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals;
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions['schema']]['Enums'][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema['Enums']
    ? DefaultSchema['Enums'][DefaultSchemaEnumNameOrOptions]
    : never;

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema['CompositeTypes']
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends (PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions['schema']]['CompositeTypes']
    : never) = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals;
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions['schema']]['CompositeTypes'][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema['CompositeTypes']
    ? DefaultSchema['CompositeTypes'][PublicCompositeTypeNameOrOptions]
    : never;

export const Constants = {
  public: {
    Enums: {
      organization_role: ['admin', 'editor', 'viewer'],
    },
  },
} as const;
